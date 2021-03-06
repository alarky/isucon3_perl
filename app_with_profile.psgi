use FindBin;
use lib "$FindBin::Bin/extlib/lib/perl5";
use lib "$FindBin::Bin/lib";
use File::Basename;
use Plack::Builder;
use Isucon3::Web;
use Plack::Session::Store::Redis;
use Plack::Session::State::Cookie;

my @opts = qw(sigexit=int savesrc=0 start=no file=/home/isucon/webapp/public/nytprof/nytprof.out);
$ENV{"NYTPROF"} = join ":", @opts;
require Devel::NYTProf;

my $root_dir = File::Basename::dirname(__FILE__);

my $app = Isucon3::Web->psgi($root_dir);
builder {
#    enable 'ReverseProxy';
#    enable 'Static',
#        path => qr!^/(?:(?:css|js|img)/|favicon\.ico$)!,
#        root => $root_dir . '/public';
    enable 'Plack::Middleware::Profiler::KYTProf',
		threshold => 10,
	;
    enable 'Session',
        store => Plack::Session::Store::Redis->new(
            redis_factory => sub { Redis->new(sock => '/tmp/redis.sock') }
        ),
        state => Plack::Session::State::Cookie->new(
            httponly    => 1,
            session_key => "isucon_session",
        ),
    ;
    enable sub {
        my $app = shift;
        sub {
            my $env = shift;
            DB::enable_profile();
            my $res = $app->($env);
            DB::disable_profile();
            return $res;
        };
    };
    $app;
};
