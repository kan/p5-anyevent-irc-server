package AnyEvent::IRC::Server;

use strict;
use warnings;
our $VERSION = '0.02';
use base qw/Object::Event Class::Accessor::Fast/;
use AnyEvent::Handle;
use AnyEvent::Socket;
use AnyEvent::IRC::Util qw/parse_irc_msg mk_msg/;
use Sys::Hostname;
use POSIX;
use Scalar::Util qw/refaddr/;

__PACKAGE__->mk_accessors(qw/host port handles servername channels topics spoofed_nick prepared_cb nick2handle/);

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
        handles      => {}, # refaddr($handle) => $handle
        channels     => {},
        topics       => {},
        spoofed_nick => {},
        nick2handle  => {}, # $nick => $hanldle,
        welcome      => 'Welcome to the my IRC server',
        servername   => hostname(),
        network      => 'AnyEventIRCServer',
        ctime        => POSIX::strftime( '%Y-%m-%d %H:%M:%S', localtime() ),
        channel_chars => '#&',
        prepared_cb  => sub {
            my ($self, $host, $port) = @_;
            print "$class is ready on : $host:$port\n";
        },
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
            if ($self->nick2handle->{$nick}) {
                return $say->($handle, ERR_NICKNAMEINUSE, $nick, 'Nickname already in use');
            }
            $handle->{nick} = $nick;
            $self->nick2handle->{$nick} = $handle;
            # TODO: broadcast to each user
        },
        user => sub {
            my ($self, $msg, $handle) = @_;
            my ($user, $host, $server, $realname) = @{$msg->{params}};
            # TODO: Note that hostname and servername are normally ignored by the IRC server when the USER command comes from a directly connected client (for security reasons)
            $handle->{user} = $user;
            $handle->{hostname} = $host;
            $handle->{servername} = $server;
            $handle->{realname} = $realname;

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
                my $nick = $handle->{nick};
                $self->channels->{$chan}->{handles}->{$nick} = $handle;

                # server reply
                $say->( $handle, RPL_TOPIC(), $chan, $self->topics->{$chan} || '' );
                $say->( $handle, RPL_NAMREPLY(), $chan, "duke" ); # TODO

                # send join message
                my $comment = sprintf '%s!%s@%s', $nick, $nick, $self->servername;
                # my $comment = sprintf '%s!%s@%s', $nick, $handle->{user}, $handle->{servername};
                my $raw = mk_msg($comment, 'JOIN', $chan) . $CRLF;
                for my $handle (values %{$self->channels->{$chan}->{handles}}) {
                    $handle->push_write($raw);
                }
                $self->event('daemon_join' => $nick, $chan);
            }
        },
        part => sub {
            my ($self, $msg, $handle) = @_;
            my ($chans, $text) = @{$msg->{params}};
            unless ($chans) {
                return $need_more_params->($handle, 'PART');
            }
            for my $chan ( split /,/, $chans ) {
                my $nick = $handle->{nick};
                $self->_intern_part($nick, $chan, $text);
                $self->event('daemon_part' => $nick, $chan);
            }
        },
        topic => sub {
            my ($irc, $msg, $handle) = @_;
            my ($chan, $topic) = @{$msg->{params}};
            unless ($chan) {
                return $need_more_params->($handle, 'TOPIC');
            }
            if ($topic) {
                $say->( $handle, RPL_TOPIC, $self->topics->{$chan} );
                my $nick = $handle->{nick};
                $self->_intern_topic($nick, $chan, $topic);
                $self->event('daemon_topic' => $nick, $chan, $topic);
            } else {
                $say->( $handle, RPL_NOTOPIC, $chan, 'No topic is set' );
            }
        },
        'privmsg' => sub {
            my ($irc, $msg, $handle) = @_;
            my ($chan, $text) = @{$msg->{params}};
            unless ($chan) {
                return $need_more_params->($handle, 'PRIVMSG');
            }
            my $nick = $handle->{nick};
            $self->_intern_privmsg($nick, $chan, $text);
            $self->event('daemon_privmsg' => $nick, $chan, $text);
        },
        'notice' => sub {
            my ($irc, $raw, $handle) = @_;
            my ($chan, $msg) = @{$raw->{params}};
            unless ($msg) {
                return $need_more_params->($handle, 'NOTICE');
            }
            my $nick = $handle->{nick};
            $self->_intern_notice($nick, $chan, $msg);
            $self->event('daemon_notice' => $nick, $chan, $msg);
        },
        'list' => sub {
            my ($irc, $raw, $handle) = @_;
            my ($chans, $msg) = @{$raw->{params}};
            $self->_intern_list($handle, $chans);
        },
        who => sub {
            my ($irc, $msg, $handle) = @_;
            my ($name) = @{$msg->{params}};

             unless ( $self->channels->{$name} ) {
                return $need_more_params->($handle, 'WHO'); # TODO
             }

            $say->( $handle, RPL_WHOREPLY(), $name, $handle->{user}, $handle->{hostname}, $handle->{servername}, $handle->{nick},"H:1", $handle->{realname});
            $say->( $handle, RPL_ENDOFWHO(), 'END of /WHO list');
        },
    );
    return $self;
}

sub _server_comment {
    my ($self, $nick) = @_;
    return sprintf '%s!~%s@%s', $nick, $nick, $self->servername;
}

sub _send_chan_msg {
    my ($self, $nick, $chan, @args) = @_;
    # send join message
    my $handle = $self->channels->{$chan}->{handles}->{$nick};
    my $comment = sprintf '%s!%s@%s', $nick, $handle->{user} || $nick, $handle->{servername} || $self->servername;
    my $raw = mk_msg($comment, @args) . $CRLF;
    if ($self->is_channel_name($chan)) {
        for my $handle (values %{$self->channels->{$chan}->{handles}}) {
            next if $handle->{nick} eq $nick;
            $handle->push_write($raw);
        }
    } else {
        # private talk
        # TODO: TOO SLOW
        my $handle = $self->nick2handle->{$chan};
        if ($handle) {
            $handle->push_write($raw);
        }
    }
}

sub run {
    my $self = shift;
    tcp_server $self->{host}, $self->{port}, sub {
        my ($fh, $host, $port) = @_;
        my $handle = AnyEvent::Handle->new(
            on_error => sub {
                my ($handle) = @_;
                $self->event('on_error' => $handle);
            },
            on_eof => sub {
                my ($handle) = @_;
                $self->event('on_eof' => $handle);
                # TODO: part from each channel
                if (my $nick = $handle->{nick}) {
                    delete $self->nick2handle->{$nick};
                }
                delete $self->handles->{refaddr($handle)};
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
        $self->handles->{refaddr($handle)} = $handle;
    }, $self->prepared_cb();
}

sub handle_msg {
    my ($self, $msg, $handle) = @_;
    my $event = lc($msg->{command});
       $event =~ s/^(\d+)$/irc_$1/g;
    $self->event($event, $msg, $handle);
}

# -------------------------------------------------------------------------

sub add_spoofed_nick {
    my ($self, $nick) = @_;
    $self->{spoofed_nick}->{$nick} = 1;
}


# -------------------------------------------------------------------------

sub daemon_cmd_join {
    my ($self, $nick, $chan, $msg, $handle) = @_;
    $self->_intern_join($nick, $chan, $handle);
}

sub daemon_cmd_kick {
    my ($self, $kicker, $chan, $kickee, $comment) = @_;
    $self->_intern_kick($kicker, $chan, $kickee, $comment);
}

sub daemon_cmd_topic {
    my ($self, $nick, $chan, $topic) = @_;
    $self->_intern_topic($nick, $chan, $topic);
}

sub daemon_cmd_part {
    my ($self, $nick, $chan, $msg) = @_;
    $self->_intern_part($nick, $chan, $msg);
}

sub daemon_cmd_privmsg {
    my ($self, $nick, $chan, $msg) = @_;
    $self->_intern_privmsg($nick, $chan, $msg);
}

sub daemon_cmd_notice {
    my ($self, $nick, $chan, $msg) = @_;
    $self->_intern_notice($nick, $chan, $msg);
}

# -------------------------------------------------------------------------

sub _intern_list {
    my ($self, $handle, $chans) = @_;

    my $nick = $handle->{nick};
    my $comment = $self->_server_comment($nick);
    my $send = sub {
        my $raw = mk_msg($comment, @_) . $CRLF;
        $handle->push_write($raw);
    };
    my $send_rpl_list = sub {
        my $chan = shift;
        $send->(RPL_LIST, $nick, $chan, scalar keys %{$self->channels->{$chan}->{handles}},  ':'.($self->topics->{$chan} || ''));
    };
    $send->(RPL_LISTSTART, $nick, 'Channel', ':Users', 'Name');
    if ($chans) {
        for my $chan (split /,/, $chans) {
            if ($self->channels->{$chan}) {
                $send_rpl_list->($chan);
            }
        }
    } else {
        my $channels = $self->channels;
        while (my ($chan, $val) = each %$channels) {
            $send_rpl_list->($chan);
        }
    }
    $send->(RPL_LISTEND, $nick, 'End of /LIST');
}

sub _intern_privmsg {
    my ($self, $nick, $chan, $text) = @_;
    $self->_send_chan_msg($nick, $chan, 'PRIVMSG', $chan, $text);
}

sub _intern_notice {
    my ($self, $nick, $chan, $text) = @_;
    $self->_send_chan_msg($nick, $chan, 'NOTICE', $chan, $text);
}

sub _intern_topic {
    my ($self, $nick, $chan, $topic) = @_;
    $self->topics->{$chan} = $topic;
    $self->_send_chan_msg($nick, $chan, 'TOPIC', $chan, $self->topics->{$chan});
}

sub _intern_join {
    my ($self, $nick, $chan, $handle) = @_;
    $self->channels->{$chan}->{handles}->{$nick} = $handle;
    $self->_send_chan_msg($nick, $chan, 'JOIN', $chan);
}

sub _intern_part {
    my ($self, $nick, $chan, $msg) = @_;
    $msg ||= $nick;

    # send part message
    $self->_send_chan_msg($nick, $chan, 'PART', $chan, $msg);
    delete $self->channels->{$chan}->{handles}->{$nick};
}

# /KICK <channel> <user> [<comment>]
# use this line in /kick: $self->event('daemon_kick' => $kicker, $chan, $kickee, $comment);
sub _intern_kick {
    my ($self, $kicker, $chan, $kickee, $comment) = @_;

    # TODO: implement
    # TODO: oper check
    my $handle = $self->channels->{$chan}->{handles}->{$kicker};
    my $cmt_irc = sprintf '%s!%s@%s', $kicker, $handle->{user} || $kicker , $handle->{servername} || $self->servername;
    my $raw = mk_msg($cmt_irc, 'KICK', $chan, $kickee, $comment) . $CRLF;
    for my $handle (values %{$self->channels->{$chan}->{handles}}) {
        $handle->push_write($raw);
    }
    delete $self->channels->{$chan}->{handles}->{$kickee};
}

# -------------------------------------------------------------------------

sub is_channel_name {
    my ( $self, $string ) = @_;
    my $cchrs = $self->{channel_chars};
    $string =~ /^([\Q$cchrs\E]+)(.+)$/;
}

1;
__END__

=head1 NAME

AnyEvent::IRC::Server - An event based IRC protocol server API

=head1 SYNOPSIS

  use AnyEvent::IRC::Server;

=head1 DESCRIPTION

AnyEvent::IRC::Server is

=head1 ROADMAP

    - useful for XIRCD
    -- authentication

    - useful for public irc server
    -- anti flooder
    -- limit nick length
    -- detect nick colision
    -- support /kick
    -- mode support
    -- who support

=head1 AUTHOR

Kan Fushihara E<lt>default {at} example.comE<gt>

Tokuhiro Matsuno

=head1 SEE ALSO

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
