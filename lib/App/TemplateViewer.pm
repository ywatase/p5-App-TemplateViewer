use YAML::Any;

package App::TemplateViewer;
use strict;
use warnings;
use version 0.77; our $VERSION = qv('v0.3.0');

use Encode 'encode_utf8';
use Template;
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
            my $tt = Template->new(%{$config{tv}{tt2}}) or croak $Template::ERROR;
            my $html;
            $tt->process(\$text, $var, \$html)  or croak $tt->error();
            return $html;
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
            my $tx   = Text::Xslate->new( module => ['Text::Xslate::Bridge::TT2Like'], %{$config{tv}{tx}});
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
$converters->{tterse} = {
    process => sub {
        my ( $text, $var ) = @_;
        my $tx = Text::Xslate->new(
            syntax => 'TTerse',
            module => ['Text::Xslate::Bridge::TT2Like'],
            %{$config{tv}{tterse}},
        );
        return $tx->render_string( $text, $var );
    },
    analize => $converters->{tt2}->{analize},
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
                sync     => $config{sync} || undef,
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
  [% IF have_local_static_files %]
  <link rel="Stylesheet" href="/template_viewer_static/jquery-ui-themes-1.8.16/themes/redmond/jquery-ui.css" type="text/css" />
  <script type="text/javascript" src="/template_viewer_static/jquery.min.js"></script>
  <script type="text/javascript" src="/template_viewer_static/jquery-ui.min.js"></script>
  [% ELSE %]
  <link rel="Stylesheet" href="http://ajax.googleapis.com/ajax/libs/jqueryui/1.8.16/themes/redmond/jquery-ui.css" type="text/css" />
  <script type="text/javascript" src="https://www.google.com/jsapi"></script>
  <script type="text/javascript">google.load("jquery", "1.6.2");</script>
  <script type="text/javascript">google.load("jqueryui", "1.8.16");</script>
  [% END %]
  <script type="text/javascript">
    <!--
    [% INCLUDE "jquery_ev.tt" %]
    // -->
  </script>
  <script type="text/javascript">
    <!--
    [% INCLUDE "jquery_selectbox.tt" %]
    // -->
  </script>
  <script type="text/javascript">
    $(function () {
      // jquery ui
      $("input:checkbox, input:button, a").button();
      $("span[name^=buttonset_]").each(function () {
        $(this).buttonset();
      });
      $("select[name^=selectbox_]").each(function () {
        $(this).selectbox();
        $(this).next().next().attr({title: $(this).attr("title")});
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
        var format    = $('#selectbox_format option:selected').val();
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
      $('#selectbox_format option:selected').change(function () { load_preview() });
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
      $('input[name="file_sync"]:checkbox').change( function () {
        if(this.checked){
          evloop_start();
        }
        else{
          evloop_stop();
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
      function evloop_start () { 
        $.ev.loop('/poll?path=[% path | uri %]&client_id=' +Math.random())
      }
      function evloop_stop () { 
        $.ev.stop();
      }

      // initialize
      $(function () {
        load_preview();
        resize_all();
        [% IF sync %]
        evloop_start();
        [% END %]
      });
    });
    function open_link (path) {
      var format = $('#selectbox_format option:selected').val();
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
               [% FOREACH dir IN dirs %]
               [% cnt = cnt + 1 %]
               <li><input type="button" name="change_path" id="change_path_[% cnt %]" value="[% basename(dir) %]/"></li>
                   <input type="hidden" name="hidden_change_path" id="hidden_change_path_[% cnt %]" value="[% dir.resolve %]">
               [% END %]
               [% FOREACH file IN files %]
               [% cnt = cnt + 1 %]
               <li><input type="button" name="change_path" id="change_path_[% cnt %]" value="[% basename(file) %]"></li>
                   <input type="hidden" name="hidden_change_path" id="hidden_change_path_[% cnt %]" value="[% file.resolve %]">
               [% END %]
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
              <select id="selectbox_format" name="selectbox_format" title="変換するモジュールを選択する">
                <option value="tt2"[% IF fmt == 'tt2' %] checked="checked"[% END %]>Template-Toolkit</option>
                <option value="tterse"[% IF fmt == 'tterse' %] checked="checked"[% END %]>Text::Xslate::Syntax::TTerse</option>
                <option value="tx"[% IF  fmt == 'tx' %]  checked="checked"[% END %]>Text::Xslate</option>
                <option value="pod"[% IF fmt == 'pod' %] checked="checked"[% END %]>Pod</option>
                <option value="markdown"[% IF fmt == 'markdown' %] checked="checked"[% END %]>Markdown</option>
                <option value="xatena"[% IF fmt == 'xatena' %] checked="checked"[% END %]>はてな記法</option>
              </select>
              <span>type</span>
              <span id="buttonset_type" name="buttonset_type">
                <input type="radio" name="type"   id="radio_type1" value="process"[% IF type == 'process' %] checked="checked"[% END %]><label for="radio_type1">Process</label></li>
                <input type="radio" name="type"   id="radio_type2" value="analize"[% IF type == 'analize' %] checked="checked"[% END %]><label for="radio_type2">Analize</label></li>
              </span>
              <span>window</span>
              <input type="button" id="cmd_wopen"  value="別Windowで開く">
              [% IF sync %]
              <input type="checkbox" id="file_sync" name="file_sync" value="sync" checked="checked"><label for="file_sync">ファイル同期</label>
              [% END %]
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
          [% IF sync %]
          <dt>ファイル同期</dt>
          <dd>サーバ側のファイル編集時のプレビューOn/Offを選択します。</dd>
          [% END %]
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

@@ jquery_selectbox.tt

// http://code.google.com/p/jquery-ui-selectbox-widget/ 
/**
 * jQuery UI Selectbox
 *
 * Author: sergiy.smolyak@gmail.com
 *
 * Depends:
 *    jquery.ui.core.js
 *    jquery.ui.widget.js
 *    jquery.ui.position.js
 *    jquery.ui.autocomplete.js
 *    jquery.ui.button.js
 */
(function( $, undefined ) {

    $.widget( "ui.selectbox", {
        options: {
            appendTo: "body",
            height: 1.4, // default control height (em)
            position: {
                my: "left top",
                at: "left bottom",
                collision: "none"
            }
        },
        _create: function() {
            var self = this;
            var select = this.element.hide();
            var input = this.input = $( "<input/>" )
                .insertAfter(select)
                .addClass( "ui-autocomplete-input ui-widget ui-widget-content ui-corner-left" )
                .attr({
                    readonly: true,
                    autocomplete: "off",
                    role: "textbox",
                    "aria-selectbox": "list",
                    "aria-haspopup": "true"
                })
                .css({
                    height: "" + this.options.height + "em",
                    lineHeight: "" + this.options.height + "em"
                })
                .bind( "keydown.selectbox", function( event ) {
                    if ( self.options.disabled ) {
                        return;
                    }
    
                    var keyCode = $.ui.keyCode;
                    switch( event.keyCode ) {
                    case keyCode.PAGE_UP:
                        self._move( "previousPage", event );
                        break;
                    case keyCode.PAGE_DOWN:
                        self._move( "nextPage", event );
                        break;
                    case keyCode.UP:
                        self._move( "previous", event );
                        // prevent moving cursor to beginning of text field in some browsers
                        event.preventDefault();
                        break;
                    case keyCode.DOWN:
                        self._move( "next", event );
                        // prevent moving cursor to end of text field in some browsers
                        event.preventDefault();
                        break;
                    case keyCode.ENTER:
                    case keyCode.NUMPAD_ENTER:
                        // when menu is open or has focus
                        if ( self.menu.element.is( ":visible" ) ) {
                            event.preventDefault();
                        }
                        //passthrough - ENTER and TAB both select the current element
                    case keyCode.TAB:
                        if ( !self.menu.active ) {
                            return;
                        }
                        self.menu.select( event );
                        break;
                    case keyCode.ESCAPE:
                        self.close( event );
                        break;
                    default:
                        // keypress is triggered before the input value is changed
                        break;
                    }
                })
                .bind( "focus.selectbox", function( event ) {
                    if ( self.options.disabled ) {
                        return;
                    }
                    self.selectedItem = null;
                    self.previous = self.element.val();
                    input
                        .addClass( "ui-corner-tl" )
                        .removeClass( "ui-corner-left" );
                    button
                        .addClass( "ui-state-focus ui-corner-tr" )
                        .removeClass( "ui-corner-right" );
                    self.open( event );
                })
                .bind( "blur.selectbox", function( event ) {
                    if ( self.options.disabled ) {
                        return;
                    }
                    button.removeClass( "ui-state-focus" );
                    input
                        .addClass( "ui-corner-left" )
                        .removeClass( "ui-corner-tl" );
                    button
                        .addClass( "ui-corner-right" )
                        .removeClass( "ui-state-focus ui-corner-tr" );
                    // clicks on the menu (or a button) will cause a blur event
                    self.closing = setTimeout(function() {
                        self.close( event );
                        self._change( event );
                    }, 150 );
                });
            var button = this.button = $( "<button>&nbsp;</button>" )
                .insertAfter(input)
                .button({
                    icons: {
                        primary: "ui-icon-triangle-1-s"
                    },
                    text: false
                }).removeClass( "ui-corner-all" )
                .addClass( "ui-corner-right ui-button-icon" )
                .height( input.outerHeight() )
                .children( ".ui-button-text" )
                    .css({
                        height: "" + this.options.height + "em",
                        lineHeight: "" + this.options.height + "em"
                    })
                    .parent()
                .css({ overflow: "hidden" })
                .position({
                    my: "left center",
                    at: "right center",
                    of: input,
                    offset: "-1 0"
                })//.css("top", "")
                .click(function( event ) {
                    // close if already visible
                    if (self.menu.element.is( ":visible" )) {
                        self.close( event );
                    } else {
                        // pass focus to input element to open menu
                        input.focus();
                    }
                    // prevent submit
                    return false;
                });
            this.refresh();
        },
        refresh: function() {
            var self = this;
            var doc = this.element[ 0 ].ownerDocument;
            if (this.menu !== undefined) {
                this.menu.element.remove();
            } 
            this.menu = $( "<ul></ul>" )
                .css({ opacity: 0 }) // hide element but allow to render
                .appendTo( $( this.options.appendTo || "body", doc )[0] )
                // prevent the close-on-blur in case of a "slow" click on the menu (long mousedown)
                .mousedown(function( event ) {
                    // clicking on the scrollbar causes focus to shift to the body
                    // but we can't detect a mouseup or a click immediately afterward
                    // so we have to track the next mousedown and close the menu if
                    // the user clicks somewhere outside of the selectbox
                    var menuElement = self.menu.element[ 0 ];
                    if ( event.target === menuElement ) {
                        setTimeout(function() {
                            $( document ).one( "mousedown", function( event ) {
                                if ( event.target !== self.element[ 0 ] &&
                                    event.target !== menuElement &&
                                    !$.ui.contains( menuElement, event.target ) ) {
                                    self.close();
                                }
                            });
                        }, 1 );
                    }
                    // use another timeout to make sure the blur-event-handler on the input was already triggered
                    setTimeout(function() {
                        clearTimeout( self.closing );
                    }, 13);
                })
                .menu({
                    focus: function( event, ui ) {
                        var item = ui.item.data( "item.selectbox" );
                        if ( false !== self._trigger( "focus", null, { item: item } ) ) {
                            // use value to match what will end up in the input, if it was a key event
                            if ( /^key/.test(event.originalEvent.type) ) {
                                self.element.val( item.value );
                            }
                        }
                    },
                    selected: function( event, ui ) {
                        var item = ui.item.data( "item.selectbox" ),
                            previous = self.previous;
    
                        // only trigger when focus was lost (click on menu)
                        if ( self.element[0] !== doc.activeElement ) {
                            self.element.focus();
                            self.previous = previous;
                        }
    
                        if ( false !== self._trigger( "select", event, { item: item } ) ) {
                            self.input.val( item.innerHTML );
                            self.element.val( item.value ).change();
                        }
    
                        self.close( event );
                        self.selectedItem = item;
                    },
                    blur: function( event, ui ) {
                    }
                })
                .removeClass( "ui-corner-all" )
                .addClass( "ui-corner-bottom ui-autocomplete" )
                .zIndex( this.element.zIndex() + 1 )
                // workaround for jQuery bug #5781 http://dev.jquery.com/ticket/5781
                .css({ top: 0, left: 0 })
                .data( "menu" );
            this._renderMenu( this.element.get(0).options );
            this.menu.element
                .outerWidth( Math.max(
                    this.menu.element.width( "" ).outerWidth(), // Menu Width
                    this.input.outerWidth() + this.button.outerWidth() - 1 // Control Width
                ))
                .position( $.extend( { of: this.input }, this.options.position ))
                .hide()
                .css({ opacity: 1 }); // remove transparency
            if ( $.fn.bgiframe ) {
                 this.menu.element.bgiframe();
            }
        },
    
        destroy: function() {
            this.input.remove();
            this.button.remove();
            this.element
                .removeClass( "ui-autocomplete-input ui-widget ui-widget-content ui-corner-left" )
                .removeAttr( "autocomplete" )
                .removeAttr( "readonly" )
                .removeAttr( "role" )
                .removeAttr( "aria-selectbox" )
                .removeAttr( "aria-haspopup" )
                .show();
            this.menu.element.remove();
            $.Widget.prototype.destroy.call( this );
        },
    
        _setOption: function( key, value ) {
            $.Widget.prototype._setOption.apply( this, arguments );
            if ( key === "source" ) {
                this._initSource();
            }
            if ( key === "appendTo" ) {
                this.menu.element.appendTo( $( value || "body", this.element[0].ownerDocument )[0] )
            }
        },
    
        open: function( event ) {
            clearTimeout( this.closing );
            if ( !this.menu.element.is( ":visible" ) ) {
                this._trigger( "open", event );
                this.menu.deactivate();
                this.menu.refresh();
                this.menu.element.show()
            }
        },
    
        close: function( event ) {
            clearTimeout( this.closing );
            if ( this.menu.element.is( ":visible" ) ) {
                this._trigger( "close", event );
                this.menu.element.hide();
                this.menu.deactivate();
                this.input.blur();
            }
        },
        
        _change: function( event ) {
            if ( this.previous !== this.element.val() ) {
                this._trigger( "change", event, { item: this.selectedItem } );
            }
        },
    
        _renderMenu: function( items ) {
            var ul = this.menu.element
                    .empty()
                    .zIndex( this.element.zIndex() + 1 ),
                menuWidth,
                textWidth;
            var self = this;
            $.each( items, function( index, item ) {
                if (item.selected) {
                    self.input.val(item.innerHTML);
                }
                self._renderItem( ul, item );
            });
            this.menu.deactivate();
            this.menu.refresh();
        },
    
        _renderItem: function( ul, item) {
            return $( "<li></li>" )
                .data( "item.selectbox", item )
                .append( $( "<a></a>" ).text( item.innerHTML ) ) // or item.label or item.text
                .appendTo( ul );
        },
    
        _move: function( direction, event ) {
            if ( !this.menu.element.is(":visible") ) {
                this.search( null, event );
                return;
            }
            if ( this.menu.first() && /^previous/.test(direction) ||
                    this.menu.last() && /^next/.test(direction) ) {
                this.menu.deactivate();
                return;
            }
            this.menu[ direction ]( event );
        },
    
        widget: function() {
            return this.menu.element;
        }
    });
    
}( jQuery ));

__END__

=head1 NAME

App::TemplateViewer - template viewer

=head1 SYNOPSIS

  templateviewer -t target_directory

=head1 DESCRIPTION

templateviewer is a script to show realtime preview of templates.

  templateviewer

start plack server, then you can access by browser http://localhost:5000/.

=head2 sync textarea edit to preview

if you change texarea on templateviewer, template viewer sync preview immediately.

=head2 sync local edit to preview

if you change template file, templateviewer sync preview immediately.

=head2 apply yaml to template variables

you can apply hashref from yaml to template.
you check condition of template easily.

=head1 INSTALLTION

  perl Makefile.PL
  cpanm --installdeps .
  make install

to see command help, run

  templateviewer --help

=head1 DEPENDENCIES

L<Tatsumaki>, L<Plack>, L<Path::Class>
L<Text::Xslate>, L<Text::Xslate::Bridge::TT2Like>
L<Pod::Simple::XHTML>, L<Text::Markdown>
L<Text::Xatena>, L<Template>, L<Getopt::Long>

=head1 AUTHOR

ywatase E<lt>ywatase@gmail.comE<gt>

=head1 SEE ALSO

L<Tatsumaki>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
