use YAML::Any;

package App::TemplateViewer;
use strict;
use warnings;
our $VERSION = '0.02';

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

my %config = ();

sub run {
    my ( $class, $args ) = @_;
    %config = %$args;
    my $app = Tatsumaki::Application->new(
        [
            "/poll"              => 'App::TemplateViewer::PollHandler',
            "/preview"           => 'App::TemplateViewer::PreviewHandler',
            "/reflesh"           => 'App::TemplateViewer::RefleshHandler',
            "/load_vars"         => 'App::TemplateViewer::LoadVarsHandler',
            "/save_vars"         => 'App::TemplateViewer::SaveVarsHandler',
            "/yaml_list"         => 'App::TemplateViewer::YamlListHandler',
            "/yaml_senario_list" => 'App::TemplateViewer::YamlSenarioListHandler',
            "/"                  => 'App::TemplateViewer::RootHandler',
        ]
    );
    $app->static_path( dirname(__FILE__) . "/../../static" );
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
            my ( $text, $var ) = @_;
            my $tx = Text::Xslate->new(
                syntax => 'TTerse',
                module => ['Text::Xslate::Bridge::TT2Like'],
            );
            return $tx->render_string( $text, $var );
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

sub get_data_files {
    my ($target_dir) = @_;
    unless ( -d $target_dir->stringify ) { $target_dir->mkpath }
    my $hash = App::TemplateViewer::get_files($target_dir);
    return map { $_->basename } _is_yaml( @{ $hash->{files} } );
}

sub _is_yaml {
    my ( @files ) = @_;
    my @yaml;
    foreach my $file (@files) {
        push @yaml, $file if -e $file->resolve and $file->basename =~ /\.ya?ml\z/msx;
    }
    return @yaml;
}

package App::TemplateViewer::FileWatcher;
use Tatsumaki::MessageQueue;
use AnyEvent;
use AnyEvent::HTTP;
use Carp;

sub new {
    my $class = shift;
    my %args = @_ == 1 ? %{ $_[0] } : @_;
    bless {%args}, $class;
}

# copy from Plack::Loader::Restarter
sub _kill_child {
    my $self = shift;

    my $pid = $self->{pid} or return;
    warn "Killing the existing server (pid:$pid)\n";
    kill 'TERM' => $pid;
    waitpid( $pid, 0 );
}

# copy from Plack::Loader::Restarter
sub _valid_file {
    my ( $self, $file ) = @_;
    $file->{path} !~ m![/\\][\._]|\.bak$|~$|_flymake\.p[lm]!;
}

sub _send_update_message {
    my ( $self, @update ) = @_;
    my $cv = AnyEvent->condvar;
    foreach my $ev (@update) {
        $cv->begin;

        # TODO change server ip and port for script args
        http_get "http://127.0.0.1:5000/reflesh?path=" . $ev->{path}, sub {
            warn "Send http request to queue message for update file : " . $ev->{path};
            $cv->end;
        };
    }
    $cv->recv;
}

sub run {
    my ( $self, $path ) = @_;
    $self->{pid} = fork;
    croak "fork() failed: $!" unless defined $self->{pid};
    return unless $self->{pid};

    # parent watch file
    require Filesys::Notify::Simple;

    # change watch path
    my $watcher = Filesys::Notify::Simple->new( $self->{watch} );
    warn "Watching @{$self->{watch}} for file updates.\n";
    local $SIG{TERM} = sub { $self->_kill_child; exit(0); };

    while (1) {
        my @update;
        $watcher->wait(
            sub {
                my @events = @_;
                @events = grep $self->_valid_file($_), @events;
                return unless @events;
                @update = @events;
            }
        );

        next unless @update;

        foreach my $ev (@update) {
            warn "-- $ev->{path} updated.\n";
        }

        $self->_send_update_message(@update);
        warn "Successfully send update message!\n";
        return unless $self->{pid};
    }
}

package App::TemplateViewer::PollHandler;
use base qw(Tatsumaki::Handler);
__PACKAGE__->asynchronous(1);

use Tatsumaki::MessageQueue;

sub get {
    my ($self) = @_;

    # TODO inputcheck
    my $channel   = $self->request->param('path') || 'mq';
    my $mq        = Tatsumaki::MessageQueue->instance($channel);
    my $client_id = $self->request->param('client_id')
        or Tatsumaki::Error::HTTP->throw( 500, "'client_id' needed" );
    $client_id = rand(1) if $client_id eq 'dummy';    # for benchmarking stuff
    $mq->poll_once( $client_id, sub { $self->on_new_event(@_) } );
}

sub on_new_event {
    my ( $self, @events ) = @_;
    $self->write( \@events );
    $self->finish;
}

package App::TemplateViewer::RefleshHandler;
use base qw(Tatsumaki::Handler);
use Encode;

sub get {
    my ($self) = @_;

    # TODO add error handling
    my $channel = $self->request->param('path') || 'mq';
    my $string  = Path::Class::file( $self->request->param('path') )->slurp;
    my $mq      = Tatsumaki::MessageQueue->instance($channel);
    $mq->publish(
        {   type    => "reflesh",
            string  => $string,
            address => $self->request->address,
            time    => scalar Time::HiRes::gettimeofday,
        }
    );
    $self->write( { success => 1 } );
}

package App::TemplateViewer::PreviewHandler;
use base qw(Tatsumaki::Handler);
use YAML::Any;

sub post {
    my ($self) = @_;
    my $v = $self->request->parameters;
    my $fmt  = $v->{format} || $config{format};
    my $type = $v->{type}   || 'process';
    my $text = $v->{text};
    my $var  = Load $v->{variables};

    my $converter
        = $converters->{$fmt}
        ? $converters->{$fmt}->{$type}
        : undef;
    my $content = $converter ? $converter->( $text, $var ) : '';
    return $self->write( Encode::encode_utf8($content) );
}

package App::TemplateViewer::YamlListHandler;
use base qw(Tatsumaki::Handler);

sub post {
    my $self = shift;

    # TODO inputcheck
    my $path    = $self->request->param('path');
    my $request = $self->request->param('request');
    my $target_file = Path::Class::dir($config{data}, $path);
    if ( not -d $target_file->stringify ) {
        return $self->write( { success => 0, errmsg  => "not valid path: $target_file" } );
    }

    my @yamls = App::TemplateViewer::get_data_files($target_file);
    @yamls = grep { m{$request} } @yamls if $request !~ m{\A\s*\z}msx;
    $self->write( { success => 1, list => \@yamls, errmsg => "$target_file" } );
}

package App::TemplateViewer::YamlSenarioListHandler;
use base qw(Tatsumaki::Handler);

sub post {
    my $self = shift;

    my $file    = $self->request->param('file');
    my $path    = $self->request->param('path');
    my $request = $self->request->param('request');
    my $target_file = Path::Class::file($config{data}, $path, $file);

    if (not -e $target_file->stringify){
        return $self->write( { success => 0, errmsg => "$target_file is not found" } );
    }
    my $yaml    = YAML::Any::LoadFile($target_file->stringify)
      or return $self->write( { success => 0, errmsg => "fail to load : $target_file" } );
    
    my @senarios   = keys %$yaml;
    @senarios = grep { m{$request} } @senarios if $request !~ m{\A\s*\z}msx;
    $self->write( { success => 1, list => \@senarios } );
}

package App::TemplateViewer::SaveVarsHandler;
use base qw(Tatsumaki::Handler);

use YAML::Any;

sub post {
    my ($self)   = @_;
    my $file     = $self->request->param('file');
    my $path     = $self->request->param('path');
    my $senario  = $self->request->param('senario');
    my $yaml_tmp = Load $self->request->param('variables');
    my $yaml;

    my $target_file = Path::Class::file($path, $file);
    if ( not $target_file->parent->subsumes(Path::Class::dir($config{data})->resolve->absolute)) {
        $target_file = Path::Class::file($config{data}, $path, $file);
    }
    if ($senario) {
        $yaml = -e $target_file->stringify ? YAML::Any::LoadFile($file->stringify) : Load '';
        $yaml->{$senario} = $yaml_tmp;
    }
    else {
        $yaml = $yaml_tmp;
    }
    YAML::Any::DumpFile( $target_file->stringify, $yaml );
    return $self->write( { success => 1 } );
}

package App::TemplateViewer::LoadVarsHandler;
use base qw(Tatsumaki::Handler);

use YAML::Any;

sub post {
    my ($self)  = @_;
    my $file    = $self->request->param('file');
    my $path    = $self->request->param('path');
    my $senario = $self->request->param('senario');

    my $target_file = Path::Class::file($path, $file);
    if ( not $target_file->parent->subsumes(Path::Class::dir($config{data})->resolve->absolute)) {
        $target_file = Path::Class::file($config{data}, $path, $file);
    }
    if (not -e $target_file->stringify){
        return $self->write( { success => 0, errmsg => "$target_file is not found" } );
    }
    my $yaml    = YAML::Any::LoadFile($target_file->stringify);
    my $result  = $yaml;
    if ( $senario and exists $yaml->{$senario} ) {
        $result = $yaml->{$senario};
    }
    return $self->write( { success => 1, file => "$target_file", data => Encode::encode_utf8 Dump $result });
}

package App::TemplateViewer::RootHandler;
use base qw(Tatsumaki::Handler);

use Carp;
use Path::Class;
use File::Basename;
use Text::Xslate;
use Data::Section::Simple qw(get_data_section);

sub get {
    my ($self) = @_;
    my $path;
    my $string = q{};

    my $v        = $self->request->parameters;
    my $fmt      = $v->{format} || $config{format};
    my $type     = $v->{type} || 'process';
    my $path_str = $v->{path} || $config{target};

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
    my $h     = App::TemplateViewer::get_files( $path->is_dir ? $path : $path->parent );
    my $vpath = get_data_section();
    my $tx    = Text::Xslate->new(
        +{  'syntax' => 'TTerse',
            'module' => ['Text::Xslate::Bridge::TT2Like'],
            'path'   => [$vpath],
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
    .tv_menu {
      font-family: "Consolas", "Courier New", Courier, mono, serif;
      font-size: 12px;
    }
    ul.tv_menu {
      margin: 0px;
      padding: 0px;
    }
    .tv_menu_title {
      font-weight: bold;
    }
    ul.tv_menu li {
      list-style-type: none;
      float:   left;
    }
    .clearfix {
      clear: both;
    }
    div#tv_sidebar {
      width: 10%;
      float: left;
      font-family: "Consolas", "Courier New", Courier, mono, serif;
      font-size: 12px;
    }
    div#tv_sidebar li {
      list-style-type: none;
      padding: 0px;
    }
    div#tv_content {
      width: 90%;
      float: left;
    }
    body {
      margin: 10px;
      background-color: #ffffff;
    }
    textarea {
      width: 100%;
      height: 100px;
    }
    div#resizable {
      padding: 5px;
    }
  </style>
  <link rel="Stylesheet" href="http://ajax.googleapis.com/ajax/libs/jqueryui/1.8.16/themes/ui-darkness/jquery-ui.css" type="text/css" />
  <script type="text/javascript" src="https://www.google.com/jsapi"></script>
  <script type="text/javascript">google.load("jquery", "1.6.2");</script>
  <script type="text/javascript">google.load("jqueryui", "1.8.16");</script>
  <script type="text/javascript">
    <!--
    [% include "jquery_ev.tt" %]
    // -->
  </script>
  <script type="text/javascript">
    $(function () {
      // jquery ui
      $("input:radio, input:checkbox, input:button, a").button();
      var child_window;
      var preview = $('#preview');
      $("#resizable").resizable({
        resize: function(event, ui) {
          preview.css({
            height: $(this).height(),
            width:  $(this).width()
          });
        },
      });

      function load_preview () {
        var text      = $('#source').val();
        var variables = $('#variables').val();
        var format    = $('input:radio[name=format]:checked').val();
        var type      = $('input:radio[name=type]:checked').val();
        $.ajax({
          url: '/preview',
          type: 'POST',
          data: {
            text: text,
            format: format,
            type: type,
            variables: variables
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
      function load_variables () {
        var path    = $('#path').val();
        var file    = $('#yaml_path').val();
        var senario = $('#yaml_senario').val();
        $.ajax({
          url: '/load_vars',
          type: 'POST',
          data: {
            file:    file,
            path:    path,
            senario: senario,
          },
          success: function (data) {
            if ( data.success == 1 ){
              console.log(data.file);
              $('#variables').val(data.data);
              load_preview();
            }
            else {
              console.log(data.errmsg);
              alert(data.errmsg);
            }
          },
          dataType: 'json',
        });
      };
      function save_variables () {
        var path      = $('#path').val();
        var file      = $('#yaml_path').val();
        var senario   = $('#yaml_senario').val();
        var variables = $('#variables').val();
        $.ajax({
          url: '/save_vars',
          type: 'POST',
          data: {
            file:    file,
            path:    path,
            senario: senario,
            variables: variables
          },
          success: function (result) {
            load_preview();
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
    
      // event
      $('#source').focus().keyup(function () { load_preview() });
      $('input[name="format"]:radio').change(function () { load_preview() });
      $('input[name="type"]:radio').change(function () { load_preview() });
      $(function () { load_preview() });
      
      $('#cmd_wopen').click(function () { wopen () });
      $('#cmd_wclose').click(function () { wclose () });
      $('#cmd_apply_variables').click(function () { load_preview() });
      $('#cmd_load_variables').click(function () { load_variables() });
      $('#cmd_save_variables').click(function () { save_variables() });

      var yaml_auto_load_flag = 1;
      $('input[name="yaml_auto_load"]:checkbox').change( function () {
        if(this.checked){
          yaml_auto_load_flag = 1;
        }
        else{
          yaml_auto_load_flag = 0;
        }
      });
      var show_tmpl_var_flag = 1;
      $('input[name="show_tmpl_var"]:checkbox').change( function () {
        console.log(show_tmpl_var_flag);
        console.log(this.checked);
        if ( (this.checked ^ show_tmpl_var_flag) ) {
          show_tmpl_var_flag = show_tmpl_var_flag ^ 1;
          $('#tmpl_var_tool').toggle("clip")
        }
      });
      
      window.addEventListener("unload", function(){
          if(!child_window) return false; 
          child_window.close();
        }, false
      );

      // autocomplete
      $('#yaml_path').autocomplete({ 
        change: function(){ 
          if (yaml_auto_load_flag == 1) { load_variables(); }
        },
        source: function(request, response){
          var path = $('#path').val();
          $.ajax({
            url: '/yaml_list',
            type: 'POST',
            data: {
              path:       path,
              request:    request.term,
            },
            success: function (data, status, xhr) {
              console.log(data.errmsg);
              if ( data.success == 1 ) {
                response (data.list);
              }
              else {
                console.log(data.errmsg);
              }
            },
            dataType: 'json',
          });
        }
      });
      $('#yaml_senario').autocomplete({ 
        change: function(){ 
          if (yaml_auto_load_flag == 1) { load_variables(); }
        },
        source: function(request, response){
          var path = $('#path').val();
          var file = $('#yaml_path').val();
          $.ajax({
            url: '/yaml_senario_list',
            type: 'POST',
            data: {
              path:       path,
              file:       file,
              request:    request.term,
            },
            success: function (data, status, xhr) {
              if ( data.success == 1 ) {
                response (data.list);
              }
              else {
                console.log(data.errmsg);
              }
            },
            dataType: 'json',
          });
        }
      });


      // listen for events
      $.ev.handlers.reflesh = function (ev) {
        try {
          $('#source').val(ev.string);
          load_preview();
        } catch(ev) { if (console) console.log(ev) }
      };
      $.ev.handlers.message = function (ev) {
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
  <div id="tv_sidebar">
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
  <div id="tv_content" class="ui-helper-clearfix">
    <div id="tv_menu" class="tv_menu">
      <input type="hidden" name="path"  id="path"   value="[% path %]">
      <ul class="tv_menu">
        <li><span class="tv_menu_title">表示:</span></li>
        <ul>
          <li><label for="show_tmpl_var">テンプレート変数ツール</label><input type="checkbox" name="show_tmpl_var" id="show_tmpl_var" checked="checked" value="1"></li>
        </ul>
        <li><span class="tv_menu_title">format:</span></li>
        <ul>
          <li><input type="radio" name="format" id="radio1" value="tt2"[% if fmt == 'tt2' %] checked="checked"[% END %]><label for="radio1">Template-Toolkit</label></li>
          <li><input type="radio" name="format" id="radio2" value="tx"[% if  fmt == 'tx' %]  checked="checked"[% END %]><label for="radio2">Text::Xslate</label></li>
          <li><input type="radio" name="format" id="radio3" value="pod"[% if fmt == 'pod' %] checked="checked"[% END %]><label for="radio3">Pod</label></li>
          <!--
          <li><input type="radio" name="format" id="radio4" value="markdown"><label for="radio4">Markdown</label></li>
          <li><input type="radio" name="format" id="radio5" value="xatena"><label for="radio5">はてな記法</label></li>
          -->
        </ul>
        <li><span class="tv_menu_title">type:</span></li>
        <ul>
          <li><input type="radio" name="type"   id="radio_type1" value="process"[% if type == 'process' %] checked="checked"[% END %]><label for="radio_type1">Process</label></li>
          <li><input type="radio" name="type"   id="radio_type2" value="analize"[% if type == 'analize' %] checked="checked"[% END %]><label for="radio_type2">Analize</label></li>
      </ul>
      <div class="tv_menu_title clearfix">ソース</div>
      <div class="tv_menu_item">
        <textarea id="source">[% string %]</textarea>
      </div>
      <div id="tmpl_var_tool">
        <div class="tv_menu_title">テンプレート変数ツール</div>
        <div class="tv_menu_item">
          <label for="yaml_auto_load">自動読込</label><input type="checkbox" name="yaml_auto_load" id="yaml_auto_load" checked="checked" value="1">
          <label for="yaml_path">YAMLファイル</label><input type="text" name="yaml_path" id="yaml_path">
          <label for="yaml_senario">ケース</label><input type="text" name="yaml_senario" id="yaml_senario">
          <input type="button" id="cmd_load_variables" value="YAMLを読み込む">
          <input type="button" id="cmd_save_variables" value="YAMLを保存する">
          <input type="button" id="cmd_apply_variables" value="変数を適用する">
          <textarea id="variables"></textarea>
        </div>
      </div>
      <div class="tv_menu_title">ソース</div>
      <div class="tv_menu_item">
        <input type="button" id="cmd_wopen"  value="別Windowで開く">
        <input type="button" id="cmd_wclose" value="別Windowを閉じる">
      </div>
    </div>
    <hr class="clearfix">
    <div id="resizable">
      <div id="preview">show here</div>
    </div>
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
