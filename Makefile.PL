use inc::Module::Install;
name 'AnyEvent-IRC-Server';
all_from 'lib/AnyEvent/IRC/Server.pm';

requires 'AnyEvent::Util';
requires 'Object::Event';

tests 't/*.t';
author_tests 'xt';

build_requires 'Test::More';
use_test_base;
auto_include;
WriteAll;
