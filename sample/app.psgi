#!perl
use Plack::Builder;
use File::Basename;
use File::Spec;
enable "Plack::Middleware::Static",
  path => qr{^/images|js|css|static/}, root => File::Spec->catfile(dirname(__FILE__), 'htdocs');
