package App::TemplateViewer;
use strict;
use warnings;
our $VERSION = '0.01';

use Encode 'encode_utf8';
use Text::Xslate;
use Text::Xslate::Bridge::TT2Like;
use Pod::Simple::XHTML;
use Path::Class;
use Tatsumaki;
use Tatsumaki::Error;
use Tatsumaki::Application;
use Time::HiRes;
use Carp;
use File::Basename;

my %config  = ();

sub run {
    my ( $class, $args ) = @_;
    %config = %$args;
    my $app = Tatsumaki::Application->new(
        [
        "/publish" => 'App::TemplateViewer::PublishHandler',
        "/poll"    => 'App::TemplateViewer::PollHandler',
        "/preview" => 'App::TemplateViewer::PreviewHandler',
        "/reflesh" => 'App::TemplateViewer::RefleshHandler',
        "/"        => 'App::TemplateViewer::RootHandler',
        ]
    );
    $app->static_path(dirname(__FILE__) . "/../../static");
    return $app->psgi_app;
}

my $converters = {
    pod => {
        process => sub {
            my $text   = shift;
            my $parser = Pod::Simple::XHTML->new;
            $parser->html_header('');
            $parser->html_footer('');
            $parser->output_string( \my $html );
            $parser->parse_string_document($text);
            return $html;
        },
    },
    tt2 => {
        process => sub {
            my $text = shift;
            my $tx   = Text::Xslate->new(
                syntax => 'TTerse',
                module => ['Text::Xslate::Bridge::TT2Like'],
            );
            my %vars = ( test => 'hogehoge' );
            return $tx->render_string( $text, \%vars );
        },
        analize => sub {
            my $text = shift;
            my $content = join "\n", $text =~ m{\[%[\+\-]?\s*(.*?)\s*[\+\-]?%\]}gmsx;
            return "<pre>$content</pre>";
        },
    },
    tx => {
        process => sub {
            my $text = shift;
            my $tx   = Text::Xslate->new( module => ['Text::Xslate::Bridge::TT2Like'], );
            my %vars = ( test => 'hogehoge' );
            return $tx->render_string( $text, \%vars );
        },
        analize => sub {
            my $text = shift;
            my $content = join "\n", $text =~ m{<:\s*([^\s]*?)\s*:>}gmsx;
            return "<pre>$content</pre>";
        },
    },
};

sub is_supported_format {
    my ( $self, $format ) = @_;
    return $converters->{$format} ? 1 : 0;
}

sub supported_format { return keys %$converters; }

sub get_files {
    my ($path) = @_;
    my ( @dirs, @files );
    foreach my $file ( sort $path->children ) {
        if ( $file->is_dir ) {
            push @dirs, $file;
        }
        else {
            push @files, $file;
        }
    }
    return {
        dirs  => \@dirs,
        files => \@files,
    };
}

package App::TemplateViewer::FileWatcher;
use Linux::Inotify2;
use AnyEvent;
use Carp;


sub new {
    my $class = shift;
    my %args = @_ == 1 ? %{ $_[0] } : @_;
    bless { %args }, $class;
}

sub watch_file {
    my ($self, $path) = @_;

    require Filesys::Notify::Simple;

    my $watcher = Filesys::Notify::Simple->new([ "." ]);
    $watcher->wait(
        sub {
            for my $event (@_) {
                $event->{path} # full path of the file updated
            }
        }
    );
}

package App::TemplateViewer::PublishHandler;
use base qw(Tatsumaki::Handler);
use Tatsumaki::MessageQueue;
sub get {
    my $self = shift;
    my $mq = Tatsumaki::MessageQueue->instance('mq');
    $mq->publish({
            type => "message",
            time => scalar Time::HiRes::gettimeofday,
    });
    $self->write({ success => 1 });
}

package App::TemplateViewer::PollHandler;
use base qw(Tatsumaki::Handler);
__PACKAGE__->asynchronous(1);

use Tatsumaki::MessageQueue;

sub get {
    my($self) = @_;
    my $mq = Tatsumaki::MessageQueue->instance('mq');
    my $client_id = $self->request->param('client_id')
        or Tatsumaki::Error::HTTP->throw(500, "'client_id' needed");
    $client_id = rand(1) if $client_id eq 'dummy'; # for benchmarking stuff
    $mq->poll_once($client_id, sub { $self->on_new_event(@_) });
}

sub on_new_event {
    my($self, @events) = @_;
    $self->write(\@events);
    $self->finish;
}

package App::TemplateViewer::RefleshHandler;
use base qw(Tatsumaki::Handler);
use HTML::Entities;
use Encode;

sub post {
    my($self) = @_;

    my $v = $self->request->parameters;
    my $mq = Tatsumaki::MessageQueue->instance('mq');
    $mq->publish({
        type => "reflesh",
        address => $self->request->address,
        time => scalar Time::HiRes::gettimeofday,
    });
    $self->write({ success => 1 });
}

package App::TemplateViewer::PreviewHandler;
use base qw(Tatsumaki::Handler);

sub post {
    my ($c)      = @_;
    my $v        = $c->request->parameters;
    my $fmt      = $v->{format} || $config{format};
    my $type     = $v->{type}   || 'process';
    my $text     = $v->{text};

    my $converter
        = $converters->{$fmt}
        ? $converters->{$fmt}->{$type}
        : undef;
    my $content = $converter ? $converter->( $text ) : '';
    return $c->write(Encode::encode_utf8($content));
}

package App::TemplateViewer::RootHandler;
use base qw(Tatsumaki::Handler);

use Carp;
use Path::Class;
use File::Basename;
use Text::Xslate;
use Data::Section::Simple qw(get_data_section);

sub get {
    my($self) = @_;
    my $path;
    my $string = q{};

    my $v        = $self->request->parameters;
    my $fmt      = $v->{format} || $config{format};
    my $type     = $v->{type} || 'process';
    my $path_str = $v->{path} || $config{dir};

    if ( not -e $path_str ) {
        return $self->response->redirect("/?format=$fmt&type=$type");
    }
    elsif ( -d $path_str or -l $path_str ) {
        $path = dir $path_str;
    }
    elsif ( -f $path_str ) {
        $path   = file $path_str;
        $string = $path->slurp;
        #App::TemplateViewer::watch_file($path);
    }
    else {
        croak "var path_str has error: $path_str";
    }
    my $h = App::TemplateViewer::get_files( $path->is_dir ? $path : $path->parent );
    my $vpath = get_data_section();
    my $tx = Text::Xslate->new(+{
            'syntax'   => 'TTerse',
            'module'   => [ 'Text::Xslate::Bridge::TT2Like' ],
            'path'     => [ $vpath ],
            },
        );
    return $self->finish(
        $tx->render(
            'index.tt',
            {   files    => $h->{files},
                dirs     => $h->{dirs},
                parent   => $path->parent,
                path     => $path,
                basename => sub { return basename $_[0] },
                string   => $string,
                fmt      => $fmt,
                type     => $type,
            },
        )
    );
}

1;

__DATA__

@@ index.tt
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <style>
    </style>
    <title>[% path %]</title>
  </head>
  <style>
    div#sidebar {
      width: 10%;
      float: left;
    }
    div#content {
      width: 90%;
      float: left;
    }
    body {
      background-color: lightgray;
      margin: 10px;
    }
    textarea {
      width: 100%;
      height: 100px;
    }
    div#preview {
      background-color: white;
      padding: 5px;
    }
  </style>
  <script type="text/javascript" src="https://www.google.com/jsapi"></script>
  <script type="text/javascript">google.load("jquery", "1.6.2");</script>
  <script type="text/javascript">
  <!--
  [% include "jquery_ev.tt" %]
  // -->
  </script>
  <script type="text/javascript">
    $(function () {
      var child_window;
      var preview = $('#preview');
      preview.css({
        height: $(window).height() - preview.offset().top - 20,
        overflow: 'auto'
      });
      function load_preview () {
        var text   = $('textarea').val();
        var format = $('input:radio[name=format]:checked').val();
        var type   = $('input:radio[name=type]:checked').val();
        $.ajax({
          url: '/preview',
          type: 'POST',
          data: {
            text: text,
            format: format,
            type: type
          },
          success: function (result) {
            $(preview).html(result);
            if ( child_window ) {
              child_window.document.clear();
              child_window.document.open();
              child_window.document.write(result);
              child_window.document.close();
            }
          }
        });
      };
      function wopen () {
        if ( ! child_window || child_window.closed ) {
          child_window = window.open();
          child_window.addEventListener("unload", function(){ child_window = undefined; }, false );
        }
        load_preview()
      };
      function wclose () {
        child_window.close();
      };

      $('textarea').focus().keyup(function () { load_preview() });
      $('input[name="format"]:radio').change(function () { load_preview() });
      $('input[name="type"]:radio').change(function () { load_preview() });
      $(function () { load_preview() });

      $('#cmd_wopen').click(function () { wopen () });
      $('#cmd_wclose').click(function () { wclose () });

      window.addEventListener("unload", function(){
        if(!child_window) return false; 
          child_window.close();
      }, false );


      // listen for events
      $.ev.handlers.reflesh = function (ev) {
        try {
          load_preview();
        } catch(ev) { if (console) console.log(ev) }
      };
      $.ev.handlers.message = function (ev) {
        $(preview).html(ev.type);
        alert(ev.type);
      };
      $.ev.loop('/poll?path=[% path | uri %]&client_id=' +Math.random())
    });
    function open_link (path) {
      var format = $('input:radio[name=format]:checked').val();
      var type   = $('input:radio[name=type]:checked').val();
      var url    = '?format=' + format + '&type=' + type + '&path=' + path;
      window.open(url, "_self");
      return false;
    }
  </script>
  <body>
    <div id="sidebar">
    <ul>
      <li><a href="#" onclick="open_link('[% parent %]');">../</a></li>
    [% foreach dir in dirs %]
      <li><a href="#" onclick="open_link('[% dir.resolve %]');">[% basename(dir) %]/</a></li>
    [% end %]
    [% foreach file in files %]
      <li><a href="#" onclick="open_link('[% file.resolve %]');">[% basename(file) %]</a></li>
    [% end %]
    </ul>
    </div>
    <div id="content">
    <!--
    <input type="radio" name="format" id="radio1" value="markdown"><label for="radio1">Markdown</label>
    <input type="radio" name="format" id="radio2" value="xatena"><label for="radio2">はてな記法</label>
    -->
    <input type="radio" name="format" id="radio3" value="tt2"[% if fmt == 'tt2' %] checked="checked"[% END %]><label for="radio3">Template-Toolkit</label>
    <input type="radio" name="format" id="radio4" value="tx"[% if  fmt == 'tx' %] checked="checked"[% END %]><label for="radio4">Text::Xslate</label>
    <input type="radio" name="format" id="radio5" value="pod"[% if fmt == 'pod' %] checked="checked"[% END %]><label for="radio5">Pod</label>
    <br>
    <input type="radio" name="type"   id="radio_type1" value="process"[% if type == 'process' %] checked="checked"[% END %]><label for="radio_type1">Process</label>
    <input type="radio" name="type"   id="radio_type2" value="analize"[% if type == 'analize' %] checked="checked"[% END %]><label for="radio_type2">Analize</label>

    <textarea>[% string %]</textarea>
    <input type="button" id="cmd_wopen"  value="別Windowで開く">
    <input type="button" id="cmd_wclose" value="別Windowを閉じる">
    <hr>
    <div id="preview"></div>
    </div>
  </body>
</html>

@@ jquery_ev.tt

/* Title: jQuery.ev
 *
 * A COMET event loop for jQuery
 *
 * $.ev.loop long-polls on a URL and expects to get an array of JSON-encoded
 * objects back.  Each of these objects should represent a message from the COMET
 * server that's telling your client-side Javascript to do something.
 *
 */
(function($){

  $.ev = {

    handlers : {},
    running  : false,
    xhr      : null,
    verbose  : true,
    timeout  : null,

    /* Method: run
     *
     * Respond to an array of messages using the object in this.handlers
     *
     */
    run: function(messages) {
      var i, m, h; // index, event, handler
      for (i = 0; i < messages.length; i++) {
        m = messages[i];
        if (!m) continue;
        h = this.handlers[m.type];
        if (!h) h = this.handlers['*'];
        if ( h) h(m);
      }
    },

    /* Method: stop
     *
     * Stop the loop
     *
     */
    stop: function() {
      if (this.xhr) {
        this.xhr.abort();
        this.xhr = null;
      }
      this.running = false;
    },

    /*
     * Method: loop
     *
     * Long poll on a URL
     *
     * Arguments:
     *
     *   url
     *   handler
     *
     */
    loop: function(url, handlers) {
      var self = this;
      if (handlers) {
        if (typeof handlers == "object") {
          this.handlers = handlers;
        } else if (typeof handlers == "function") {
          this.run = handlers;
        } else {
          throw("handlers must be an object or function");
        }
      }
      this.running = true;
      this.xhr = $.ajax({
        type     : 'GET',
        dataType : 'json',
        cache    : false,
        url      : url,
        timeout  : self.timeout,
        success  : function(messages, status) {
          // console.log('success', messages);
          self.run(messages)
        },
        complete : function(xhr, status) {
          var delay;
          if (status == 'success') {
            delay = 100;
          } else {
            // console.log('status: ' + status, '; waiting before long-polling again...');
            delay = 5000;
          }
          // "recursively" loop
          window.setTimeout(function(){ if (self.running) self.loop(url); }, delay);
        }
      });
    }

  };

})(jQuery);

__END__

=head1 NAME

App::TemplateViewer -

=head1 SYNOPSIS

  use App::TemplateViewer;

=head1 DESCRIPTION

App::TemplateViewer is

=head1 AUTHOR

ywatase E<lt>ywatase@gmail.comE<gt>

=head1 SEE ALSO

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
