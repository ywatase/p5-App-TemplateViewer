use inc::Module::Install;
name 'App-TemplateViewer';
all_from 'lib/App/TemplateViewer.pm';
readme_from 'lib/App/TemplateViewer.pm';
readme_markdown_from 'lib/App/TemplateViewer.pm';
readme_pod_from 'lib/App/TemplateViewer.pm';
githubmeta;

requires 'Text::Xslate';
requires 'Text::Xslate::Bridge::TT2Like';
requires 'Pod::Simple::XHTML';
requires 'Text::Xatena';
requires 'Text::Markdown';
requires 'Template';
requires 'Plack';
requires 'Tatsumaki';
requires 'Path::Class';
requires 'AnyEvent';
requires 'AnyEvent::HTTP';
requires 'Filesys::Notify::Simple';
requires 'Tatsumaki';
requires 'Tatsumaki::Error';
requires 'Tatsumaki::Application';
requires 'Tatsumaki::MessageQueue';
requires 'Time::HiRes';
requires 'Carp';
requires 'File::Basename';
requires 'Encode';
requires 'Data::Section::Simple';
requires 'YAML::Any';

install_script 'bin/templateviewer';

tests 't/*.t';
author_tests 'xt';

build_requires 'Test::More';
auto_set_repository;
auto_include;
WriteAll;
