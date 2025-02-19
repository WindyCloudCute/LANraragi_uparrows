package LANraragi::Utils::Minion;

use strict;
use warnings;

use Encode;
use Mojo::UserAgent;
use Parallel::Loops;

use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Database qw(redis_decode);
use LANraragi::Utils::Archive qw(extract_thumbnail extract_archive);
use LANraragi::Utils::Plugins qw(get_downloader_for_url get_plugin get_plugin_parameters use_plugin);
use LANraragi::Utils::Generic qw(trim_url split_workload_by_cpu);
use LANraragi::Utils::TempFolder qw(get_temp);

use LANraragi::Model::Upload;
use LANraragi::Model::Config;
use LANraragi::Model::Stats;

# Add Tasks to the Minion instance.
sub add_tasks {
    my $minion = shift;

    $minion->add_task(
        thumbnail_task => sub {
            my ( $job, @args ) = @_;
            my ( $thumbdir, $id, $page ) = @args;

            my $logger = get_logger( "Minion", "minion" );

            # Non-cover thumbnails are rendered in low quality by default.
            my $use_hq = $page eq 0 || LANraragi::Model::Config->get_hqthumbpages;
            my $thumbname = "";

            eval { $thumbname = extract_thumbnail( $thumbdir, $id, $page, $use_hq ); };
            if ($@) {
                my $msg = "Error building thumbnail: $@";
                $logger->error($msg);
                $job->fail( { errors => [$msg] } );
            } else {
                $job->finish($thumbname);
            }

        }
    );

    $minion->add_task(
        regen_all_thumbnails => sub {
            my ( $job,      @args )  = @_;
            my ( $thumbdir, $force ) = @args;

            my $logger = get_logger( "Minion", "minion" );
            my $redis  = LANraragi::Model::Config->get_redis;
            my @keys   = $redis->keys('????????????????????????????????????????');
            $redis->quit();

            $logger->info("开始缩略图重新生成作业 (强制模式 = $force)");
            my @errors = ();

            my $numCpus = Sys::CpuAffinity::getNumCpus();
            my $pl      = Parallel::Loops->new($numCpus);
            $pl->share( \@errors );

            $logger->debug("可用于处理的核心数量: $numCpus");
            my @sections = split_workload_by_cpu( $numCpus, @keys );

            # Regen thumbnails for errythang if $force = 1, only missing thumbs otherwise
            eval {
                $pl->foreach(
                    \@sections,
                    sub {
                        foreach my $id (@$_) {

                            my $subfolder = substr( $id, 0, 2 );
                            my $thumbname = "$thumbdir/$subfolder/$id.jpg";

                            unless ( $force == 0 && -e $thumbname ) {
                                eval {
                                    $logger->debug("正在重新生成:$id...");
                                    extract_thumbnail( $thumbdir, $id, 0, 1 );
                                };

                                if ($@) {
                                    $logger->warn("生成缩略图时出错: $@");
                                    push @errors, $@;
                                }
                            }
                        }
                    }
                );
            };

            $job->finish( { errors => \@errors } );
        }
    );

    $minion->add_task(
        build_stat_hashes => sub {
            my ( $job, @args ) = @_;
            LANraragi::Model::Stats->build_stat_hashes;
            $job->finish;
        }
    );

    $minion->add_task(
        handle_upload => sub {
            my ( $job,  @args )  = @_;
            my ( $file, $catid ) = @args;

            my $logger = get_logger( "Minion", "minion" );

# Superjank warning for the code below.
#
# Filepaths are left unencoded across all of LRR to avoid any headaches with how the filesystem handles filenames with non-ASCII characters.
# (Some FS do UTF-8 properly, others not at all. We use File::Find, which returns direct bytes, to always have a filepath that matches the FS.)
#
# By "unencoded" tho, I actually mean Latin-1/ISO-8859-1.
# Perl strings are internally either in Latin-1 or non-strict utf-8 ("utf8"), depending on the history of the string.
# (See https://perldoc.perl.org/perlunifaq#I-lost-track;-what-encoding-is-the-internal-format-really?)
#
# When passing the string through the Minion pipe, it gets switched to utf8 for...reasons? ¯\_(ツ)_/¯
# This actually breaks the string and makes it no longer match the real name/byte sequence if it contained non-ASCII characters,
# so we use this arcane dark magic function to switch it back.
# (See https://perldoc.perl.org/perlunicode#Forcing-Unicode-in-Perl-(Or-Unforcing-Unicode-in-Perl))
            utf8::downgrade( $file, 1 )
              or die "Bullshit! File path could not be converted back to a byte sequence!"
              ;    # This error happening would not make any sense at all so it deserves the EYE reference

            $logger->info("正在处理上传的文件 $file...");

            # Since we already have a file, this goes straight to handle_incoming_file.
            my ( $status, $id, $title, $message ) = LANraragi::Model::Upload::handle_incoming_file( $file, $catid, "" );

            $job->finish(
                {   success  => $status,
                    id       => $id,
                    category => $catid,
                    title    => redis_decode($title),    # Fix display issues in the response
                    message  => $message
                }
            );
        }
    );

    $minion->add_task(
        download_url => sub {
            my ( $job, @args )  = @_;
            my ( $url, $catid ) = @args;

            my $ua = Mojo::UserAgent->new;
            my $logger = get_logger( "Minion", "minion" );
            $logger->info("正在下载 $url...");

            # Keep a clean copy of the url for display and tagging
            my $og_url = $url;
            trim_url($og_url);

            # 如果已记录URL，请流产下载
            my $recorded_id = LANraragi::Model::Stats::is_url_recorded($og_url);
            if ($recorded_id) {
                $job->finish(
                    {   success => 0,
                        url     => $og_url,
                        id      => $recorded_id,
                        message => "链接已被下载!"
                    }
                );
                return;
            }

            # Check downloader plugins for one matching the given URL
            my $downloader = get_downloader_for_url($url);

            if ($downloader) {

                $logger->info( "发现下载器 " . $downloader->{namespace} );

                # Use the downloader to transform the URL
                my $plugname = $downloader->{namespace};
                my $plugin   = get_plugin($plugname);
                my @settings = get_plugin_parameters($plugname);

                my $plugin_result = LANraragi::Model::Plugins::exec_download_plugin( $plugin, $url, @settings );

                if ( exists $plugin_result->{error} ) {
                    $job->finish(
                        {   success => 0,
                            url     => $url,
                            message => $plugin_result->{error}
                        }
                    );
                }

                $ua  = $plugin_result->{user_agent};
                $url = $plugin_result->{download_url};
                $logger->info("插件将 URL 转换为 $url");
            } else {
                $logger->debug("找不到下载器，尝试直接下载 URL.");
            }

            # Download the URL
            eval {
                my $tempfile = LANraragi::Model::Upload::download_url( $url, $ua );
                $logger->info("URL将会被保存为 $tempfile ");

                # Add the url as a source: tag
                my $tag = "source:$og_url";

                # Hand off the result to handle_incoming_file
                my ( $status, $id, $title, $message ) = LANraragi::Model::Upload::handle_incoming_file( $tempfile, $catid, $tag );

                $job->finish(
                    {   success  => $status,
                        url      => $og_url,
                        id       => $id,
                        category => $catid,
                        title    => $title,
                        message  => $message
                    }
                );
            };

            if ($@) {

                # Downloading failed...
                $job->finish(
                    {   success => 0,
                        url     => $og_url,
                        message => $@
                    }
                );
            }
        }
    );

    $minion->add_task(
        run_plugin => sub {
            my ( $job, @args ) = @_;
            my ( $namespace, $id, $scriptarg ) = @args;

            my $logger = get_logger( "Minion", "minion" );
            $logger->info("运行插件 $namespace...");

            my ( $pluginfo, $plugin_result ) = use_plugin( $namespace, $id, $scriptarg );

            $job->finish(
                {   type    => $pluginfo->{type},
                    success => ( exists $plugin_result->{error} ? 0 : 1 ),
                    error   => $plugin_result->{error},
                    data    => $plugin_result
                }
            );
        }
    );

    $minion->add_task(
        extract_archive => sub {
            my ( $job, @args )  = @_;
            my ( $id,  $force ) = @args;

            my $tempdir = get_temp();
            my $path    = $tempdir . "/" . $id;
            my $redis   = LANraragi::Model::Config->get_redis;

            # Get the path from Redis.
            # Filenames are stored as they are on the OS, so no decoding!
            my $zipfile = $redis->hget( $id, "file" );

            my $outpath = "";
            eval { $outpath = extract_archive( $path, $zipfile, $force ); };

            if ($@) {
                $job->finish(
                    {   success => 0,
                        id      => $id,
                        message => $@
                    }
                );
            } else {
                $job->finish(
                    {   success => 1,
                        id      => $id,
                        outpath => $outpath
                    }
                );
            }
        }
    );
}

1;
