requires 'AnyEvent::IRC';
requires 'Object::Event';
requires 'Class::Accessor::Fast';

on 'configure' => sub {
    requires 'Module::Build' => '0.38';
    requires 'Module::Build::Pluggable';
    requires 'Module::Build::Pluggable::CPANfile';
};

on 'test' => sub {
    requires 'Test::More' => '0.98';
    requires 'Test::Requires' =>  0;
    requires 'Test::TCP';
};
