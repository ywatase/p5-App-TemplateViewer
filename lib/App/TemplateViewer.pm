use YAML::Any;

package App::TemplateViewer;
use strict;
use warnings;
use version 0.77; our $VERSION = qv('v0.3.0');

use Encode 'encode_utf8';
use Text::Xslate;
use Text::Xslate::Bridge::TT2Like;
use Pod::Simple::XHTML;
use Text::Markdown 'markdown';
use Text::Xatena;
use Path::Class;
use Tatsumaki;
use Tatsumaki::Error;
use Tatsumaki::Application;
use Plack::Middleware::Static;
use Carp;
use YAML::Any;
use File::Basename;

my %config = ();

sub new {
    my $class = shift;
    my %args = @_ == 1 ? %{ $_[0] } : @_;
    bless {%args}, $class;
}

sub run {
    my ( $class, $args ) = @_;
    %config = %$args;
    my $app = Tatsumaki::Application->new(
        [   "/poll"              => 'App::TemplateViewer::PollHandler',
            "/preview"           => 'App::TemplateViewer::PreviewHandler',
            "/reflesh"           => 'App::TemplateViewer::RefleshHandler',
            "/load_vars"         => 'App::TemplateViewer::LoadVarsHandler',
            "/save_vars"         => 'App::TemplateViewer::SaveVarsHandler',
            "/yaml_list"         => 'App::TemplateViewer::YamlListHandler',
            "/yaml_senario_list" => 'App::TemplateViewer::YamlSenarioListHandler',
            "/"                  => 'App::TemplateViewer::RootHandler',
        ]
    );
    $app = $app->psgi_app;
    warn have_local_static_files();
    if (have_local_static_files()) {
        $app = Plack::Middleware::Static->wrap($app, path => sub { s|^/template_viewer_static/|| }, root => config_dir()->subdir('static')->stringify);
    }
    return $app;
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
            my ( $text, $var ) = @_;
            my $tx   = Text::Xslate->new( module => ['Text::Xslate::Bridge::TT2Like'], );
            return $tx->render_string( $text, $var);
        },
        analize => sub {
            my $text = shift;
            my $content = join "\n", $text =~ m{<:\s*([^\s]*?)\s*:>}gmsx;
            return "<pre>$content</pre>";
        },
    },

    markdown => {
        process => sub {
            my $text = shift;
            return markdown($text);
        },
    },
    xatena => {
        process => sub {
            my $text = shift;
            return Text::Xatena->new->format($text);
        }
    }
};

my $static_files = {
    jquery          => {
        url => q|https://ajax.googleapis.com/ajax/libs/jquery/1.6.3/jquery.min.js|
    },
    jquery_ui       => {
        url => q|http://ajax.googleapis.com/ajax/libs/jqueryui/1.8.16/jquery-ui.min.js|
    },
    jquery_ui_theme => {
        url => q|http://jquery-ui.googlecode.com/files/jquery-ui-themes-1.8.16.zip|,
        post => sub {
            ! system 'unzip', $_[0] or die $!;
        },
    },
};

sub config_dir {
    return  dir($ENV{HOME}, '.templateviewer');
}

sub have_local_static_files {
    my ($self) = @_;
    foreach my $v (values %$static_files) {
        warn config_dir()->file('static', basename $v->{url})->stringify;
        return 0 if not -e config_dir()->file('static', basename $v->{url})->stringify;
    }
    return 1;
}

sub init {
    my ($self) = @_;
    if ( not ref $self ) {
        $self = $self->new;
    }
    $self->make_config_dir;
    $self->get_static_files;
}

sub make_config_dir {
    my ($self) = @_;
    -e $self->config_dir->stringify or $self->config_dir->mkpath;
}

sub get_static_files {
    my ($self) = @_;
    require Cwd;
    my $current_dir = Cwd::getcwd;
    my $static_dir  = $self->config_dir->subdir('static');
    -e $static_dir->stringify or $static_dir->mkpath;
    chdir $static_dir  or croak "chdir error: $!";
    while ( my ( $k, $v ) = each %$static_files ) {
        $self->_download ( $v->{url} );
        exists $v->{post} and $v->{post}->(basename $v->{url});
    }
    chdir $current_dir;
}

sub _download {
    my ($self, $url) = @_;
    $self->{_http_client} ||= _get_http_client() or croak "supported http client is not found";
    $self->{_http_client}->($url);
}
sub _get_http_client {
    my %clients = (
        curl => sub {
            my ($url) = @_;
            ! system('curl' ,'-LO', $url) or croak "failed to download $url";
        },
        wget => sub {
            my ($url) = @_;
            ! system('wget' ,'-LO', $url) or croak "failed to download $url";
		},
    );
    foreach my $k (qw(curl wget)) {
        if ( _can_run_by_shell($k) ) {
            return $clients{$k};
        }
    }
    return;
}
sub _can_run_by_shell {
    return not (system("which $_[0] >/dev/null 2>&1"));
}

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
    my (@files) = @_;
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

sub post {
    my ($self) = @_;
    my $v = $self->request->parameters;
    my $fmt  = $v->{format} || $config{format};
    my $type = $v->{type}   || 'process';
    my $text = $v->{text};
    my $var  = YAML::Any::Load $v->{variables};

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
    my $path        = $self->request->param('path');
    my $request     = $self->request->param('request');
    my $target_file = Path::Class::dir( $config{data}, $path );
    if ( not -d $target_file->stringify ) {
        return $self->write( { success => 0, errmsg => "not valid path: $target_file" } );
    }

    my @yamls = App::TemplateViewer::get_data_files($target_file);
    @yamls = grep {m{$request}} @yamls if $request !~ m{\A\s*\z}msx;
    $self->write( { success => 1, list => \@yamls, errmsg => "$target_file" } );
}

package App::TemplateViewer::YamlSenarioListHandler;
use base qw(Tatsumaki::Handler);

sub post {
    my $self = shift;

    my $file        = $self->request->param('file');
    my $path        = $self->request->param('path');
    my $request     = $self->request->param('request');
    my $target_file = Path::Class::file( $config{data}, $path, $file );

    if ( not -e $target_file->stringify ) {
        return $self->write( { success => 0, errmsg => "$target_file is not found" } );
    }
    my $yaml = YAML::Any::LoadFile( $target_file->stringify )
        or return $self->write( { success => 0, errmsg => "fail to load : $target_file" } );

    my @senarios = keys %$yaml;
    @senarios = grep {m{$request}} @senarios if $request !~ m{\A\s*\z}msx;
    $self->write( { success => 1, list => \@senarios } );
}

package App::TemplateViewer::SaveVarsHandler;
use base qw(Tatsumaki::Handler);

use Carp;

sub post {
    my ($self)   = @_;
    my $file     = $self->request->param('file');
    my $path     = $self->request->param('path');
    my $senario  = $self->request->param('senario');
    my $yaml_tmp = YAML::Any::Load $self->request->param('variables');
    my $yaml;

    my $target_file = Path::Class::file( $path, $file );
    if (not $target_file->parent->subsumes( Path::Class::dir( $config{data} )) )
    {
        $target_file = Path::Class::file( $config{data}, $path, $file );
    }
    unless ( -d $target_file->parent->stringify ) { $target_file->parent->mkpath or croak "Can't create directory: " . $target_file->parent}
    if ($senario) {
        $yaml
            = -e $target_file->stringify
            ? YAML::Any::LoadFile( $target_file->stringify )
            : YAML::Any::Load '';
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

sub post {
    my ($self)  = @_;
    my $file    = $self->request->param('file');
    my $path    = $self->request->param('path');
    my $senario = $self->request->param('senario');

    my $target_file = Path::Class::file( $path, $file );
    if (not $target_file->parent->subsumes( Path::Class::dir( $config{data} )->resolve->absolute ) )
    {
        $target_file = Path::Class::file( $config{data}, $path, $file );
    }
    if ( not -e $target_file->stringify ) {
        return $self->write( { success => 0, errmsg => "$target_file is not found" } );
    }
    my $yaml   = YAML::Any::LoadFile( $target_file->stringify );
    my $result = $yaml;
    if ( $senario and exists $yaml->{$senario} ) {
        $result = $yaml->{$senario};
    }
    return $self->write(
        {   success => 1,
            file    => "$target_file",
            data    => Encode::encode_utf8 YAML::Any::Dump $result
        }
    );
}

package App::TemplateViewer::RootHandler;
use base qw(Tatsumaki::Handler);

use Carp;
use File::Basename;
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
        $path = Path::Class::dir $path_str;
    }
    elsif ( -f $path_str ) {
        $path   = Path::Class::file $path_str;
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
                have_local_static_files => App::TemplateViewer->have_local_static_files, 
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
    <title>App::TemplpateViewer</title>
  </head>
  <style>
    body {
      margin:  2px;
      padding: 2px;
      background-color: #ffffff;
      font-family:'ヒラギノ角ゴ Pro W3','Hiragino Kaku Gothic Pro','メイリオ',Meiryo,'ＭＳ Ｐゴシック',sans-serif;
      font-size: 12px;
    }
    .tv_toolbar {
      padding: 10px 4px;
      margin:  2px;
    }
    .tv_menu_title {
      font-weight: bold;
    }
    div#tv_sidebar {
      float: left;
      font-size: smaller;
    }
    div#tv_topmenu {
      font-size: smaller;
    }
    .tv_sidebar_menu li {
      list-style-type: none;
    }
    .tv_sidebar_menu ul {
      margin: 0px;
      padding: 0px;
    }
    div.tv_content {
      width: auto;
      float: left;
    }
    div.tv_content.hide_tv_sidebar {
      width: 100%;
      clear: both;
    }
    textarea {
      margin-left: 2px;
      height: 100px;
    }
    .hide_tv_sidebar textarea {
      width: 100%;
    }
    div#resizable {
      padding: 5px;
    }
    div.tv_preview {
      width: auto;
    }
    div.tv_preview.hide_tv_sidebar {
      width: 100%;
    }
  </style>
  [% if have_local_static_files %]
  <link rel="Stylesheet" href="/template_viewer_static/jquery-ui-themes-1.8.16/themes/redmond/jquery-ui.css" type="text/css" />
  <script type="text/javascript" src="/template_viewer_static/jquery.min.js"></script>
  <script type="text/javascript" src="/template_viewer_static/jquery-ui.min.js"></script>
  [% else %]
  <link rel="Stylesheet" href="http://ajax.googleapis.com/ajax/libs/jqueryui/1.8.16/themes/redmond/jquery-ui.css" type="text/css" />
  <script type="text/javascript" src="https://www.google.com/jsapi"></script>
  <script type="text/javascript">google.load("jquery", "1.6.2");</script>
  <script type="text/javascript">google.load("jqueryui", "1.8.16");</script>
  [% end %]
  <script type="text/javascript">
    <!--
    [% include "jquery_ev.tt" %]
    // -->
  </script>
  <script type="text/javascript">
    $(function () {
      // jquery ui
      $("input:checkbox, input:button, a").button();
      $("span[name^=buttonset_]").each(function () {
        $(this).buttonset();
      });
      $("button.tv_help").each( function () {
        $(this).button({
          icons: { primary: "ui-icon-help" },
          text: false,
        });
        $(this).click( function () {
          var obj = $("#" + this.id + "_content");
          if ( obj.dialog("isOpen") ) {
            obj.dialog("close");
          }
          else {
            obj.dialog("open");
          }
        });
      });
      $("div.tv_dialog").each( function () {
        $(this).dialog({autoOpen: false});
      });

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
      $('input[name="change_path"]:button').click(function () {
        console.log(this.id);
        console.log($("#hidden_" + this.id).val() );
        open_link( $("#hidden_" + this.id).val() );
      });
      
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

      /* toggle #id by name=show_id checkbox */
      // initialize 
      var visible_flag = {};
      $('input[name^="show_"]:checkbox').each( function () {
        visible_flag[this.name] = this.checked;
      });
      // event
      $('input[name^="show_"]:checkbox').change( function () {
        if ( (this.checked ^ visible_flag[this.name]) ) {
          visible_flag[this.name] = visible_flag[this.name] ^ 1;
          var target_id = this.name.replace(/^show_/,"");
          $('#' + target_id ).toggle("clip");
          toggle_hide_class("hide_" + target_id);
        }
      });
      // toggle  hide_{id} class
      function toggle_hide_class (class) {
          console.log(class);
        var div_list = new Array ("tv_content", "tv_sidebar", "tv_menu_tmpl_var");
        for(var i in div_list){
          $("#" + div_list[i]).toggleClass(class);
        }
        resize_all ();
      }
      // ajast textarea and div.tv_preview
      function resize_all () {
        if ($("#tv_content").hasClass("hide_tv_sidebar")) {
          $('textarea').each( function () {
            $(this).css("width","100%") 
          });
          $(preview).css("width","100%");
        }
        else {
          var width = $("#tv_sidebar").width();
          $('textarea').each( function () {
            $(this).css("width",$(window).width() - width - 18);
            console.log($(this).css("width"));
          });
          $(preview).css("width",$(window).width() - width - 18);
        }
      }
      
      window.addEventListener("unload", function(){
          if(!child_window) return false; 
          child_window.close();
        }, false
      );

      /* autocomplete */
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


      // initialize
      $(function () {
        load_preview();
        resize_all();
      });
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
    <div id="tv_body">
      <div id="tv_topmenu">
          <div id="tv_menu_top" class="tv_toolbar ui-widget-header ui-corner-all">
              <button id="tv_menu_top_help" class="tv_help">トップメニューのヘルプ</button>
              <span>表示</span>
              <label for="show_tv_sidebar">ファイルリスト</label><input type="checkbox" name="show_tv_sidebar" id="show_tv_sidebar" checked="checked" value="1">
              <label for="show_tv_menu_tmpl_var">テンプレート変数</label><input type="checkbox" name="show_tv_menu_tmpl_var" id="show_tv_menu_tmpl_var" checked="checked" value="1">
          </div>
      </div>
      <div id="tv_sidebar" class="tv_sidebar">
        <div id="tv_sidebar_menu" class="tv_sidebar_menu">
          <div id="tv_menu_filelist" class="tv_toolbar ui-widget-header ui-corner-all">
            <ul>
               [% cnt = 1 %]
               <li><input type="button" name="change_path" id="change_path_[% cnt %]" value="../"></li>
                   <input type="hidden" name="hidden_change_path" id="hidden_change_path_[% cnt %]" value="[% parent %]">
               [% foreach dir in dirs %]
               [% cnt = cnt + 1 %]
               <li><input type="button" name="change_path" id="change_path_[% cnt %]" value="[% basename(dir) %]/"></li>
                   <input type="hidden" name="hidden_change_path" id="hidden_change_path_[% cnt %]" value="[% dir.resolve %]">
               [% end %]
               [% foreach file in files %]
               [% cnt = cnt + 1 %]
               <li><input type="button" name="change_path" id="change_path_[% cnt %]" value="[% basename(file) %]"></li>
                   <input type="hidden" name="hidden_change_path" id="hidden_change_path_[% cnt %]" value="[% file.resolve %]">
               [% end %]
             </ul>
          </div>
        </div>
      </div>
      <div id="tv_content" class="tv_content">
        <div id="tv_menu" class="tv_menu">
          <div id="tv_menu_main">
            <div id="toolbar" class="tv_toolbar ui-widget-header ui-corner-all">
              <button id="tv_menu_main_help" class="tv_help">メインメニューのヘルプ</button>
              <span>format</span>
              <span id="buttonset_format" name="buttonset_format">
                <input type="radio" name="format" id="radio1" value="tt2"[% if fmt == 'tt2' %] checked="checked"[% END %]><label for="radio1">Template-Toolkit</label>
                <input type="radio" name="format" id="radio2" value="tx"[% if  fmt == 'tx' %]  checked="checked"[% END %]><label for="radio2">Text::Xslate</label>
                <input type="radio" name="format" id="radio3" value="pod"[% if fmt == 'pod' %] checked="checked"[% END %]><label for="radio3">Pod</label>
                <input type="radio" name="format" id="radio4" value="markdown"[% if fmt == 'markdown' %] checked="checked"[% END %]><label for="radio4">Markdown</label>
                <input type="radio" name="format" id="radio5" value="xatena"[% if fmt == 'xatena' %] checked="checked"[% END %]><label for="radio5">はてな記法</label>
              </span>
              <span>type</span>
              <span id="buttonset_type" name="buttonset_type">
                <input type="radio" name="type"   id="radio_type1" value="process"[% if type == 'process' %] checked="checked"[% END %]><label for="radio_type1">Process</label></li>
                <input type="radio" name="type"   id="radio_type2" value="analize"[% if type == 'analize' %] checked="checked"[% END %]><label for="radio_type2">Analize</label></li>
              </span>
              <span>window</span>
              <input type="button" id="cmd_wopen"  value="別Windowで開く">
              <input type="button" id="cmd_wclose" value="別Windowを閉じる">
            </div>
            <textarea id="source">[% string %]</textarea>
          </div>
          <div id="tv_menu_tmpl_var">
            <div id="tv_menu_tmpl_var_toolbar" class="tv_toolbar ui-widget-header ui-corner-all">
              <button id="tv_menu_tmpl_var_help" class="tv_help">テンプレート変数ツールのヘルプ</button>
              <label for="yaml_path">ファイル</label><input type="text" name="yaml_path" id="yaml_path">
              <label for="yaml_senario">ケース</label><input type="text" name="yaml_senario" id="yaml_senario">
              <input type="button" id="cmd_save_variables" value="YAMLを保存する">
              <input type="button" id="cmd_load_variables" value="YAMLを読み込む">
              <input type="button" id="cmd_apply_variables" value="変数を適用する">
              <label for="yaml_auto_load">自動読込</label><input type="checkbox" name="yaml_auto_load" id="yaml_auto_load" checked="checked" value="1">
            </div>
            <textarea id="variables"></textarea>
          </div>
        </div>
        <hr>
        <div id="resizable">
          <div id="preview" class="tv_preview">show here</div>
        </div>
      </div>
      <div id="tv_menu_tmpl_var_help_content" class="tv_dialog" title="テンプレート変数ツールのヘルプ">
        <dl>
          <dt>ファイル</dt>
          <dd>YAMLファイル名を入力します。</dd>
          <dt>ケース</dt>
          <dd>YAMLファイル中のcase_で始まるものをケースとしてみなします。</dd>
          <dt>自動読み込み</dt>
          <dd>ファイル・ケースを入力すると自動的にファイルを読み込み、テンプレート変数を適用します。</dd>
        </dl>
      </div>
      <div id="tv_menu_top_help_content" class="tv_dialog" title="テンプレートビューアーについて">
        <h3>テンプレートビューアーについて</h3>
        <p>すぎゃーんさんのリアルタイムプレビューをAmon2::Liteで作成しているのをみて見て作り始めた開発補助ツールです。</p>
        <h3>特徴</h3>
        <ul>
          <li>cpanモジュールと同じインストール手法でインストールできます</li>
          <li>テンプレート変数をYAML形式で記述することでテンプレートの条件分岐を再現できます</li>
          <li>表示中のテンプレートをサーバ側で編集すると自動的にプレビューが更新されます</li>
        </ul>
        <h3>トップメニューについて</h3>
        <dl>
          <dt>表示切替</dt>
          <dd>ツールの表示・非表示を切り替えます。</dd>
        </dl>
      </div>
      <div id="tv_menu_main_help_content" class="tv_dialog" title="メインメニューのヘルプ">
        <dl>
          <dt>Format</dt>
          <dd>リアルタイムプレビューを行うのフォーマットを選択します。</dd>
          <dt>Process</dt>
          <dd>Formatで指定された形式のプレビューを表示します。</dd>
          <dt>Analyze</dt>
          <dd>Formatで指定された形式のファイルとして解析します。</dd>
          <dt>windowを開く</dt>
          <dd>別のウィンドウを開きます。Process選択時はテンプレートからHTMLを生成するため、本ツールと干渉することがあります。ディスプレイを2つ以上利用している場合オススメです。</dd>
          <dt>windowを閉じる</dt>
          <dd>別のウィンドウを閉じます。そのうちなくなります。</dd>
        </dl>
      </div>
    </div>
    <input type="hidden" name="path"  id="path"   value="[% path %]">
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
