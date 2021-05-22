package LANraragi::Utils::Generic;

use strict;
use warnings;
use utf8;
use feature "switch";
no warnings 'experimental';

use Storable qw(store);
use Digest::SHA qw(sha256_hex);
use Mojo::Log;
use Mojo::IOLoop;
use Logfile::Rotate;
use Proc::Simple;
use Sys::CpuAffinity;

use LANraragi::Utils::Logging qw(get_logger);

# Generic Utility Functions.
use Exporter 'import';
our @EXPORT_OK =
  qw(remove_spaces remove_newlines trim_url is_image is_archive render_api_response get_tag_with_namespace shasum start_shinobu
  split_workload_by_cpu start_minion get_css_list generate_themes_header generate_themes_selector);

# Remove spaces before and after a word
sub remove_spaces {
    $_[0] =~ s/^\s+|\s+$//g;
}

# Remove all newlines in a string
sub remove_newlines {
    $_[0] =~ s/\R//g;
}

# Fixes up a URL string for use in the DL system.
sub trim_url {

    remove_spaces( $_[0] );

    # Remove scheme and www. if present. Other subdomains are not removed
    if ( $_[0] =~ /https?:\/\/(www\.)?(.*)/gm ) {
        $_[0] = $2;
    }

    my $char = chop $_[0];
    if ( $char ne "/" ) {
        $_[0] .= $char;
    }
}

# Checks if the provided file is an image.
# Uses non-capturing groups (?:) to avoid modifying the incoming argument.
sub is_image {
    return $_[0] =~ /^.+\.(?:png|jpg|gif|bmp|jpeg|jfif|webp|avif|heif|heic)$/i;
}

# Checks if the provided file is an archive.
sub is_archive {
    return $_[0] =~ /^.+\.(?:zip|rar|7z|tar|tar\.gz|lzma|xz|cbz|cbr|cb7|cbt|pdf|epub|)$/i;
}

# Renders the basic success API JSON template.
# Specifying an error message argument will set the success variable to 0.
sub render_api_response {
    my ( $mojo, $operation, $errormessage ) = @_;
    my $failed = ( defined $errormessage );

    $mojo->render(
        json => {
            operation => $operation,
            error     => $failed ? $errormessage : "",
            success   => $failed ? 0 : 1
        },
        status => $failed ? 400 : 200
    );
}

# Find the first tag matching the given namespace, or return the default value.
sub get_tag_with_namespace {
    my ( $namespace, $tags, $default ) = @_;
    my @values = split( ',', $tags );

    foreach my $tag (@values) {
        my ( $namecheck, $value ) = split( ':', $tag );
        remove_spaces($namecheck);
        remove_spaces($value);

        if ( $namecheck eq $namespace ) {
            return $value;
        }
    }

    return $default;
}

# Split an array into an array of arrays, according to host CPU count.
sub split_workload_by_cpu {

    my ( $numCpus, @workload ) = @_;

    # Split the workload equally between all CPUs with an array of arrays
    my @sections;
    while (@workload) {
        foreach ( 0 .. $numCpus - 1 ) {
            if (@workload) {
                push @{ $sections[$_] }, shift @workload;
            }
        }
    }

    return @sections;
}

# Start a Minion worker if there aren't any available.
sub start_minion {
    my $mojo   = shift;
    my $logger = get_logger( "Minion", "minion" );

    my $numcpus = Sys::CpuAffinity::getNumCpus();
    $logger->info("Starting new Minion worker in subprocess with $numcpus parallel jobs.");

    my $worker = $mojo->app->minion->worker;
    $worker->status->{jobs} = $numcpus;
    $worker->on( dequeue => sub { pop->once( spawn => \&_spawn ) } );

    # https://github.com/mojolicious/minion/issues/76
    my $proc = Proc::Simple->new();
    $proc->start(
        sub {
            $logger->info("Minion worker $$ started");
            $worker->run;
            $logger->info("Minion worker $$ stopped");
            return 1;
        }
    );
    $proc->kill_on_destroy(0);

    # Freeze the process object in the PID file
    store \$proc, 'script/minion.pid';
    return $proc;
}

sub _spawn {
    my ( $job, $pid )  = @_;
    my ( $id,  $task ) = ( $job->id, $job->task );
    my $logger = get_logger( "Minion Worker", "minion" );
    $job->app->log->debug(qq{Process $pid is performing job "$id" with task "$task"});
}

# Start Shinobu and return its Proc::Background object.
sub start_shinobu {
    my $mojo = shift;

    my $proc = Proc::Simple->new();
    $proc->start( $^X, "./lib/Shinobu.pm" );
    $proc->kill_on_destroy(0);

    $mojo->LRR_LOGGER->debug( "Shinobu Worker new PID is " . $proc->pid );

    # Freeze the process object in the PID file
    store \$proc, 'script/shinobu.pid';
    return $proc;
}

#This function gives us a SHA hash for the passed file, which is used for thumbnail reverse search on E-H.
#First argument is the file, second is the algorithm to use. (1, 224, 256, 384, 512, 512224, or 512256)
#E-H only uses SHA-1 hashes.
sub shasum {

    my $digest = "";
    my $logger = get_logger( "Hash Computation", "lanraragi" );

    eval {
        my $ctx = Digest::SHA->new( $_[1] );
        $ctx->addfile( $_[0] );
        $digest = $ctx->hexdigest;
    };

    if ($@) {
        $logger->error( "Error building hash for " . $_[0] . " -- " . $@ );

        return "";
    }

    return $digest;
}

sub get_css_list {

    #Get all the available CSS sheets.
    my @css;
    opendir( DIR, "./public/themes" ) or die $!;
    while ( my $file = readdir(DIR) ) {
        if ( $file =~ /.+\.css/ ) { push( @css, $file ); }
    }
    closedir(DIR);

    return @css;
}

#Print a dropdown list to select CSS, and adds <link> tags for all the style sheets present in the /style folder.
sub generate_themes_header {

    my $self = shift;
    my @css  = get_css_list;

    #html that we'll insert in the header to declare all the available styles.
    my $html = "";

    #Go through the css files
    for ( my $i = 0; $i < $#css + 1; $i++ ) {

        my $css_name = css_default_names( $css[$i] );

        #if this is the default sheet, set it up as so.
        if ( $css[$i] eq LANraragi::Model::Config->get_style ) {

            $html =
                $html
              . '<link rel="stylesheet" type="text/css" title="'
              . $css_name
              . '" href="/themes/'
              . $css[$i] . '?'
              . $self->LRR_VERSION . '"> ';
        } else {

            $html =
                $html
              . '<link rel="alternate stylesheet" type="text/css" title="'
              . $css_name
              . '" href="/themes/'
              . $css[$i] . '?'
              . $self->LRR_VERSION . '"> ';
        }
    }

    return $html;

}

sub generate_themes_selector {

    my @css    = get_css_list;
    my $CSSsel = '<div>';

    #Go through the css files
    for ( my $i = 0; $i < $#css + 1; $i++ ) {

        #populate the div with buttons
        my $css_name = css_default_names( $css[$i] );
        $CSSsel =
            $CSSsel
          . '<input class="stdbtn" type="button" onclick="switch_style(\''
          . $css_name
          . '\');" value="'
          . $css_name . '"/>';
    }

    #close up div
    $CSSsel = $CSSsel . '</div>';

    return $CSSsel;
}

#Assign a name to the css file passed. You can add names by adding cases.
#Note: CSS files added to the /themes folder will ALWAYS be pickable by the users no matter what.
#All this sub does is give .css files prettier names in the dropdown. Files without a name here will simply show as their filename to the users.
sub css_default_names {
    given ( $_[0] ) {
        when ("g.css")            { return "HentaiVerse" }
        when ("modern.css")       { return "Hachikuji" }
        when ("modern_clear.css") { return "Yotsugi" }
        when ("modern_red.css")   { return "Nadeko" }
        when ("ex.css")           { return "Sad Panda" }
        default                   { return $_[0] }
    }
}

1;
