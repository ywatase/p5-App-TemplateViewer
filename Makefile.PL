use inc::Module::Install;
name 'App-TemplateViewer';
all_from 'lib/App/TemplateViewer.pm';
readme_from 'lib/App/TemplateViewer.pm';
readme_markdown_from 'lib/App/TemplateViewer.pm';
readme_pod_from 'lib/App/TemplateViewer.pm';
githubmeta;

requires 'Text::Xslate';
requires 'Plack';
requires 'Amon2::Lite';
requires 'Path::Class';

install_script 'bin/templateviewer';

tests 't/*.t';
author_tests 'xt';

build_requires 'Test::More';
auto_set_repository;
auto_include;
WriteAll;
