# NAME

AnyEvent::IRC::Server - An event based IRC protocol server API

# SYNOPSIS

    use AnyEvent::IRC::Server;

# DESCRIPTION

AnyEvent::IRC::Server is

# ROADMAP

    - useful for XIRCD
    -- authentication

    - useful for public irc server
    -- anti flooder
    -- limit nick length
    -- detect nick colision
    -- support /kick
    -- mode support
    -- who support

# DEBUGGING

You can trace events by [Object::Event](http://search.cpan.org/perldoc?Object::Event)'s feature.

Use the environment variable __PERL\_OBJECT\_EVENT\_DEBUG__

    export PERL_OBJECT_EVENT_DEBUG=2

# AUTHOR

Kan Fushihara <default {at} example.com>

Tokuhiro Matsuno

# SEE ALSO

# LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.
