use FindBin;
use lib "$FindBin::Bin/extlib/lib/perl5";
use lib "$FindBin::Bin/lib";
use File::Basename;
use Plack::Builder;
use Isucon3::Web;
use Plack::Session::Store::Redis;
use Plack::Session::State::Cookie;

my $root_dir = File::Basename::dirname(__FILE__);

my $app = Isucon3::Web->psgi($root_dir);
builder {
#    enable 'ReverseProxy';
#    enable 'Static',
#        path => qr!^/(?:(?:css|js|img)/|favicon\.ico$)!,
#        root => $root_dir . '/public';
    enable 'Session',
        store => Plack::Session::Store::Redis->new(
            redis_factory => sub { Redis->new(sock => '/tmp/redis.sock') }
        ),
        state => Plack::Session::State::Cookie->new(
            httponly    => 1,
            session_key => "isucon_session",
        ),
    ;
    $app;
};
