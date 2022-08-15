package LANraragi::Controller::Api::Search;
use Mojo::Base 'Mojolicious::Controller';

use List::Util qw(min);

use LANraragi::Model::Search;
use LANraragi::Utils::Generic qw(render_api_response);
use LANraragi::Utils::Database qw(invalidate_cache get_archive_json_multi);

# Undocumented API matching the Datatables spec.
sub handle_datatables {

    my $self  = shift;
    my $redis = $self->LRR_CONF->get_redis();
    my $req   = $self->req;

    my $draw   = $req->param('draw');
    my $start  = $req->param('start');
    my $length = $req->param('length');

    # Jesus christ what the fuck datatables
    my $filter    = $req->param('search[value]');
    my $sortindex = $req->param('order[0][column]');
    my $sortorder = $req->param('order[0][dir]');
    my $sortkey   = $req->param("columns[$sortindex][name]");

    # See if specific column searches were made
    my $i              = 0;
    my $categoryfilter = "";
    my $newfilter      = 0;
    my $untaggedfilter = 0;

    while ( $req->param("columns[$i][name]") ) {

        # Collection (tags column)
        if ( $req->param("columns[$i][name]") eq "tags" ) {
            $categoryfilter = $req->param("columns[$i][search][value]");
        }

        # New filter (isnew column)
        if ( $req->param("columns[$i][name]") eq "isnew" ) {
            $newfilter = $req->param("columns[$i][search][value]") eq "true";
        }

        # Untagged filter (untagged column)
        if ( $req->param("columns[$i][name]") eq "untagged" ) {
            $untaggedfilter = $req->param("columns[$i][search][value]") eq "true";
        }
        $i++;
    }

    $sortorder = ( $sortorder && $sortorder eq 'desc' ) ? 1 : 0;

    my ( $total, $filtered, @ids ) =
      LANraragi::Model::Search::do_search( $filter, $categoryfilter, $start, $sortkey, $sortorder, $newfilter, $untaggedfilter );

    $self->render( json => get_datatables_object( $draw, $redis, $total, $filtered, @ids ) );
    $redis->quit();

}

# Public search API with saner parameters.
sub handle_api {

    my $self  = shift;
    my $redis = $self->LRR_CONF->get_redis();
    my $req   = $self->req;

    my $filter    = $req->param('filter');
    my $category  = $req->param('category') || "";
    my $start     = $req->param('start');
    my $sortkey   = $req->param('sortby');
    my $sortorder = $req->param('order');
    my $newfilter = $req->param('newonly') || "false";
    my $untaggedf = $req->param('untaggedonly') || "false";

    $sortorder = ( $sortorder && $sortorder eq 'desc' ) ? 1 : 0;

    my ( $total, $filtered, @ids ) = LANraragi::Model::Search::do_search(
        $filter, $category, $start, $sortkey, $sortorder,
        $newfilter eq "true",
        $untaggedf eq "true"
    );

    $self->render( json => get_datatables_object( 0, $redis, $total, $filtered, @ids ) );
    $redis->quit();

}

sub clear_cache {
    invalidate_cache(1);
    render_api_response( shift, "clear_cache" );
}

# Pull random archives out of the given search
sub get_random_archives {

    my $self  = shift;
    my $redis = $self->LRR_CONF->get_redis();
    my $req   = $self->req;

    my $filter       = $req->param('filter');
    my $category     = $req->param('category') || "";
    my $random_count = $req->param('count') || 5;

    # Use the search engine to get IDs matching the filter/category selection, with start=-1 to get all data
    # This method could be extended later to also use isnew/untagged filters.
    my ( $total, $filtered, @ids ) = LANraragi::Model::Search::do_search( $filter, $category, -1, "title", 0, "", "" );
    my @random_ids;

    $random_count = min( $random_count, scalar(@ids) );

    while ( $random_count > 0 ) {
        my $random_id = $ids[ int( rand( scalar @ids ) ) ];
        next if ( grep { $_ eq $random_id } @random_ids );

        push @random_ids, $random_id;
        $random_count--;
    }

    $self->render( json => { data => \@random_ids } );
    $redis->quit();
}

# get_datatables_object($draw, $total, $totalsearched, @pagedkeys)
# Creates a Datatables-compatible json from the given data.
sub get_datatables_object {

    my ( $draw, $redis, $total, $filtered, @keys ) = @_;

    # Get IDs from keys
    my @ids = map { $_->{id} } @keys;

    # Get archive data
    my @data = get_archive_json_multi(@ids);

    # Create json object matching the datatables structure
    return {
        draw            => $draw,
        recordsTotal    => $total,
        recordsFiltered => $filtered,
        data            => \@data
    };
}

1;
