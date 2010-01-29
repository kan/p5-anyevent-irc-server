package t::Util;
use strict;
use warnings;
use base 'Exporter';

our @EXPORT = qw/conn/;

sub conn {
    t::Conn->new(@_);
}

{
    package t::Conn;
    use Test::More;
    use AnyEvent::IRC::Util qw/mk_msg/;
    sub new {
        my ($class, %args) = @_;
        my $port = delete $args{port} or die "missing argumetn: port";
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
        ) or die "Cannnot connect to $port: $!";
        $sock->autoflush(1);
        $sock->timeout(3);
        my $self = bless {sock => $sock,}, $class;
        if ($args{nick}) {
            $self->send_srv('nick' => $args{nick});
            $self->send_srv('user' => $args{user} || $args{nick}, '0', '*', $args{real}||$args{user});
        }
        return $self;
    }
    sub send_srv {
        my ($self, @args) = @_;
        my $msg = mk_msg(undef, @args) . "\015\012";
        $self->{sock}->syswrite($msg);
    }
    sub skip_first {
        my ($self, $expected) = @_;
        my $fh = $self->{sock};
        while (my $got = <$fh>) {
            if ($got =~ /MOTD File is missing/) {
                return;
            }
        }
    }
    sub is_response {
        my ($self, $expected) = @_;
        my $got = $self->getline();
        is $got, $expected, $expected;
    }
    sub getline {
        my ($self, $expected) = @_;
        my $fh = $self->{sock};
        my $got = <$fh>;
        $got =~ s/[\r\n]+$//;
        return $got;
    }
}

1;
