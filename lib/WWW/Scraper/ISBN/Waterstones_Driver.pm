package WWW::Scraper::ISBN::Waterstones_Driver;

use strict;
use warnings;

use vars qw($VERSION @ISA);
$VERSION = '0.09';

#--------------------------------------------------------------------------

=head1 NAME

WWW::Scraper::ISBN::Waterstones_Driver - Search driver for the Waterstones online book catalog.

=head1 SYNOPSIS

See parent class documentation (L<WWW::Scraper::ISBN::Driver>)

=head1 DESCRIPTION

Searches for book information from Waterstones online book catalog.

=cut

#--------------------------------------------------------------------------

###########################################################################
# Inheritence

use base qw(WWW::Scraper::ISBN::Driver);

###########################################################################
# Modules

use WWW::Mechanize;
use JSON::XS;

###########################################################################
# Constants

use constant REFERER => 'https://www.waterstones.com';
use constant SEARCH  => 'https://www.waterstones.com/index/search?term=';
my ($URL1,$URL2) = ('http://www.waterstones.com/book/','/[^?]+\?b=\-3\&amp;t=\-26\#Bibliographicdata\-26');

#--------------------------------------------------------------------------

###########################################################################
# Public Interface

=head1 METHODS

=over 4

=item C<search()>

Creates a query string, then passes the appropriate form fields to the 
Book Depository server.

The returned page should be the correct catalog page for that ISBN. If not the
function returns zero and allows the next driver in the chain to have a go. If
a valid page is returned, the following fields are returned via the book hash:

  isbn          (now returns isbn13)
  isbn10        
  isbn13
  ean13         (industry name)
  author
  title
  book_link
  image_link
  thumb_link
  description
  pubdate
  publisher
  binding       (if known)
  pages         (if known)

The book_link, image_link and thumb_link all refer back to the Waterstones
website.

=back

=cut

sub search {
    my $self = shift;
    my $isbn = shift;
    $self->found(0);
    $self->book(undef);

    # validate and convert into EAN13 format
    my $ean = $self->convert_to_ean13($isbn);
    return $self->handler("Invalid ISBN specified")   
        if(!$ean || (length $isbn == 13 && $isbn ne $ean)
                 || (length $isbn == 10 && $isbn ne $self->convert_to_isbn10($ean)));

    my $mech = WWW::Mechanize->new();
    $mech->agent_alias( 'Linux Mozilla' );
    $mech->add_header( 'Accept-Encoding' => undef );
    $mech->add_header( 'Referer' => REFERER );

    eval { $mech->get( SEARCH . $ean ) };
    return $self->handler("The Waterstones website appears to be unavailable.")
        if($@ || !$mech->success() || !$mech->content());

#print STDERR "\n# search=[".SEARCH."$ean]\n";
#print STDERR "\n# is_html=".$mech->is_html().", content type=".$mech->content_type()."\n";
#print STDERR "\n# dump headers=".$mech->dump_headers."\n";

    # we get back a redirect
    my $response = $mech->response();
    my $url = $response->header( 'X-Meta-Og-Url' );
#print STDERR "\n# url=[$url]\n";

    return $self->handler("Failed to find that book on the Waterstones website. [$isbn]")
        if($url eq REFERER || $url eq REFERER . "/books/search/term/$ean");

    eval { $mech->get( $url ) };
    return $self->handler("Failed to find that book on the Waterstones website. [$isbn]")
        if($@ || !$mech->success() || !$mech->content());

    # The Book page
    my $html = $mech->content();

    return $self->handler("Failed to find that book on the Waterstones website. [$isbn]")
        if($html =~ m|<strong>Sorry!</strong> We did not find any results for|si);

    return $self->handler("Waterstones website has crashed. [$isbn]")
        if($html =~ m|Exception was UseCaseError: \d+|si);

    $html =~ s/&amp;/&/g;
#print STDERR "\n# content2=[\n$html\n]\n";

    my $data;
    ($data->{title},$data->{author})
                           = $html =~ m!<title>(.*?)\s*by\s*(.*?) \| Waterstones</title>!si;
    ($data->{binding})     = $html =~ m!<span class="book-title" itemprop="name" id="scope_book_title">.*? \((.*?)\)</span>!si;
    ($data->{description}) = $html =~ m!<div itemprop="description" id="scope_book_description">(.*?)</div>!si;
    ($data->{publisher})   = $html =~ m!<span itemprop="publisher">([^<]+)</span>!si;
    ($data->{pubdate})     = $html =~ m!<meta itemprop="datePublished" content="[^"]+" />([\d\/]+)\s*</span>!si;
    ($data->{isbn13})      = $html =~ m!<span itemprop="isbn">([^<]+)</span>!si;
    ($data->{image})       = $html =~ m!<img itemprop="image" id="scope_book_image" src="([^"]+$ean.jpg)"!si;
    my ($json)             = $html =~ m!<script>\s*ws_dl = \[(.*?)\]\s*</script>!si;
#print STDERR "\n# json=[\n$json\n]\n";

    if($json) {
        $data->{json} = decode_json( $json );
        for(qw(author title imprint publication_date format)) {
            $data->{$_} = $data->{json}{'gtm-books'}[0]{$_};
        }

        $data->{binding} ||= $data->{format};
        $data->{pubdate} ||= $data->{publication_date};
    }

#use Data::Dumper;
#print STDERR "\n# data=" . Dumper($data);

    return $self->handler("Could not extract data from the Waterstones result page. [$isbn]")
        unless(defined $data);

    for(qw(author publisher description title)) {
        $data->{$_} =~ s/&#0?39;/'/g    if($data->{$_});
    }

    $data->{isbn10}      = $self->convert_to_isbn10($ean);
    $data->{title}       =~ s!\s*\($data->{binding}\)\s*!!  if($data->{title});
    $data->{description} =~ s!<[^>]+>!!                     if($data->{description});

    if($data->{image}) {
        $data->{thumb}  = $data->{image};
        $data->{thumb}  =~ s!/images/nbd/[lms]/!/images/nbd/s/!;
        $data->{image}  =~ s!/images/nbd/[lms]/!/images/nbd/l/!;
    }

#use Data::Dumper;
#print STDERR "\n# data=" . Dumper($data);

    # trim top and tail
    foreach (keys %$data) { 
        next unless(defined $data->{$_});
        $data->{$_} =~ s!&nbsp;! !g;
        $data->{$_} =~ s/^\s+//;
        $data->{$_} =~ s/\s+$//;
    }

#    my $url = $mech->uri();
#    $url =~ s/\?.*//;

    my $bk = {
        'ean13'       => $data->{isbn13},
        'isbn13'      => $data->{isbn13},
        'isbn10'      => $data->{isbn10},
        'isbn'        => $data->{isbn13},
        'author'      => $data->{author},
        'title'       => $data->{title},
        'book_link'   => "$url",
        'image_link'  => $data->{image},
        'thumb_link'  => $data->{thumb},
        'description' => $data->{description},
        'pubdate'     => $data->{pubdate},
        'publisher'   => $data->{publisher},
        'binding'     => $data->{binding},
        'pages'       => $data->{pages},
        'json'        => $data->{json},
        'html'        => $html
    };

#use Data::Dumper;
#print STDERR "\n# book=".Dumper($bk);

    $self->book($bk);
    $self->found(1);
    return $self->book;
}

1;

__END__

=head1 REQUIRES

Requires the following modules be installed:

L<JSON::XS>,
L<WWW::Mechanize>,
L<WWW::Scraper::ISBN::Driver>

=head1 SEE ALSO

L<WWW::Scraper::ISBN>,
L<WWW::Scraper::ISBN::Record>,
L<WWW::Scraper::ISBN::Driver>

=head1 BUGS, PATCHES & FIXES

There are no known bugs at the time of this release. However, if you spot a
bug or are experiencing difficulties that are not explained within the POD
documentation, please send an email to barbie@cpan.org or submit a bug to the
RT system (http://rt.cpan.org/Public/Dist/Display.html?Name=WWW-Scraper-ISBN-Waterstones_Driver).
However, it would help greatly if you are able to pinpoint problems or even
supply a patch.

Fixes are dependant upon their severity and my availablity. Should a fix not
be forthcoming, please feel free to (politely) remind me.

=head1 AUTHOR

  Barbie, <barbie@cpan.org>
  Miss Barbell Productions, <http://www.missbarbell.co.uk/>

=head1 COPYRIGHT & LICENSE

  Copyright (C) 2010-2019 Barbie for Miss Barbell Productions

  This module is free software; you can redistribute it and/or
  modify it under the Artistic Licence v2.

=cut
