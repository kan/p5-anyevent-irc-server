package AnyEvent::IRC::Server;

use strict;
use warnings;
our $VERSION = '0.01';
use base qw/Object::Event Class::Accessor::Fast/;
use AnyEvent::Handle;
use AnyEvent::Socket;
use AnyEvent::IRC::Util qw/parse_irc_msg mk_msg/;
use Sys::Hostname;
use POSIX;

__PACKAGE__->mk_accessors(qw/host port handles servername channels topics/);

my $CRLF = "\015\012";

BEGIN {
    no strict 'refs';
    while (my ($code, $name) = each %AnyEvent::IRC::Util::RFC_NUMCODE_MAP) {
        *{"${name}"} = sub () { $code };
    }
};

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(
        handles => {},
        channels => {},
        topics   => {},
        welcome => 'Welcome to the my IRC server',
        servername => hostname(),
        network    => 'AnyEventIRCServer',
        ctime      => POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime()),
        @_,
    );

    my $say = sub {
        my ($handle, $cmd, @args) = @_;
        my $msg = mk_msg($self->host, $cmd, $handle->{nick}, @args) . $CRLF;
        $handle->push_write($msg)
    };
    my $need_more_params = sub {
        my ($handle, $cmd) = @_;
        $say->($handle, ERR_NEEDMOREPARAMS, $cmd, 'Not enough parameters');
    };
    $self->reg_cb(
        nick => sub {
            my ($self, $msg, $handle) = @_;
            my ($nick) = @{$msg->{params}};
            unless ($nick) {
                return $need_more_params->($handle, 'NICK');
            }
            $handle->{nick} = $nick;
        },
        user => sub {
            my ($self, $msg, $handle) = @_;
            $say->( $handle, RPL_WELCOME(), $self->{welcome} );
            $say->( $handle, RPL_YOURHOST(), "Your host is @{[ $self->servername ]} [@{[ $self->servername ]}/@{[ $self->port ]}]. @{[ ref $self ]}/$VERSION" ); # 002
            $say->( $handle, RPL_CREATED(), "This server was created $self->{ctime}");
            $say->( $handle, RPL_MYINFO(), "@{[ $self->servername ]} @{[ ref $self ]}-$VERSION" ); # 004
            $say->( $handle, ERR_NOMOTD(), "MOTD File is missing" );
        },
        'join' => sub {
            my ($self, $msg, $handle) = @_;
            my ($chans) = @{$msg->{params}};
            unless ($chans) {
                return $need_more_params->($handle, 'JOIN');
            }
            for my $chan ( split /,/, $chans ) {
                push @{$self->channels->{$chan}->{handles}}, $handle;

                # server reply
                $say->( $handle, RPL_TOPIC(), $chan, $self->topics->{$chan} || '' );
                $say->( $handle, RPL_NAMREPLY(), $chan, "duke" ); # TODO

                # send join message
                my $nick = $handle->{nick};
                my $comment = sprintf '%s!~%s@%s', $nick, $nick, $self->servername;
                my $raw = mk_msg($comment, 'JOIN', $chan) . $CRLF;
                for my $handle (@{$self->channels->{$chan}->{handles}}) {
                    $handle->push_write($raw);
                }
                $self->event('daemon_join' => $nick, $chan);
            }
        },
        topic => sub {
            my ($irc, $msg, $handle) = @_;
            my ($chan, $topic) = @{$msg->{params}};
            unless ($chan) {
                return $need_more_params->($handle, 'TOPIC');
            }
            if ($topic) {
                $self->topics->{$chan} = $topic;
                $say->( $handle, RPL_TOPIC, $self->topics->{$chan} );
            } else {
                $say->( $handle, RPL_NOTOPIC, $chan, 'No topic is set' );
            }
            $self->_send_chan_msg($handle, $chan, 'TOPIC', $chan, $self->topics->{$chan});
        },
        'privmsg' => sub {
            my ($irc, $msg, $handle) = @_;
            my ($chan, $text) = @{$msg->{params}};
            unless ($chan) {
                return $need_more_params->($handle, 'PRIVMSG');
            }
            $self->event('daemon_privmsg' => $chan, $text);
        },
    );
    return $self;
}

sub _send_chan_msg {
    my ($self, $handle, $chan, @args) = @_;
    # send join message
    my $nick = $handle->{nick};
    my $comment = sprintf '%s!~%s@%s', $nick, $nick, $self->servername;
    my $raw = mk_msg($comment, @args) . $CRLF;
    for my $handle (@{$self->channels->{$chan}->{handles}}) {
        $handle->push_write($raw);
    }
}

sub run {
    my $self = shift;
    tcp_server $self->{host}, $self->{port}, sub {
        my ($fh, $host, $port) = @_;
        my $handle = AnyEvent::Handle->new(
            on_error => sub {
            },
            on_eof => sub {
            },
            fh => $fh,
        );
        $handle->{nick} = '*';
        $handle->on_read(sub {
            $handle->push_read(line => sub {
                my ($handle, $line, $eol) = @_;
                my $msg = parse_irc_msg($line);
                $self->handle_msg($msg, $handle);
            });
        });
        $self->handles->{fileno($fh)} = $handle;
    }, sub {
        # prepare cb
        my ($fh, $thishost, $thisport) = @_;
        $self->print_banner($thishost, $thisport);
    };
}

sub print_banner {
    my ($self, $host, $port) = @_;
    print "@{[ ref $self ]} is ready on : $host:$port\n";
}

sub handle_msg {
    my ($self, $msg, $handle) = @_;
    my $event = lc($msg->{command});
       $event =~ s/^(\d+)$/irc_$1/g;
    $self->event($event, $msg, $handle);
}

sub send_privmsg {
    my ($self, $nick, $chan, $msg) = @_;
    my $comment = sprintf '%s!~%s@%s', $nick, $nick, $self->servername;
    my $raw = mk_msg($comment, 'PRIVMSG', $chan, $msg) . $CRLF;
    for my $handle (@{$self->channels->{$chan}->{handles}}) {
        $handle->push_write($raw);
    }
}

# -------------------------------------------------------------------------

sub daemon_cmd_join {
    my ($self, $nick, $chan) = @_;
    # TODO
    $self->event('daemon_join' => $nick, $chan);
}

sub daemon_cmd_privmsg {
    my ($self, $nick, $chan, $msg) = @_;
    for my $line (split /\r?\n/, $msg) {
        $self->send_privmsg($nick, $chan, $line);
    }
}

1;
__END__

=head1 NAME

AnyEvent::IRC::Server -

=head1 SYNOPSIS

  use AnyEvent::IRC::Server;

=head1 DESCRIPTION

AnyEvent::IRC::Server is

=head1 ROADMAP

    - useful for testing
    -- support /kick
    -- notice support
    -- part support
    -- mode support
    -- who support

    - useful for XIRCD
    -- authentication

    - useful for public irc server
    -- anti flooder

=head1 AUTHOR

Kan Fushihara E<lt>default {at} example.comE<gt>

Tokuhiro Matsuno

=head1 SEE ALSO

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
