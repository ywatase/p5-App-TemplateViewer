use inc::Module::Install;
name 'App-TemplateViewer';
all_from 'lib/App/TemplateViewer.pm';
readme_from 'lib/App/TemplateViewer.pm';
readme_markdown_from 'lib/App/TemplateViewer.pm';
readme_pod_from 'lib/App/TemplateViewer.pm';
githubmeta;

# requires '';

tests 't/*.t';
author_tests 'xt';

build_requires 'Test::More';
auto_set_repository;
auto_include;
WriteAll;
