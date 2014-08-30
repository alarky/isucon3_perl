use strict;
use warnings;
use utf8;
use DBIx::Sunny;
use Redis;
use JSON::XS;
use Text::Markdown::Discount qw/markdown/;

sub d { use Data::Dumper; print Dumper(@_); }

my $start = time();

my $dbh = DBIx::Sunny->connect( "dbi:mysql:database=isucon",
                                "root",
                                "root",
                                {
                                    RaiseError => 1,
                                    PrintError => 0,
                                    AutoInactiveDestroy => 1,
                                    mysql_enable_utf8 => 1,
                                    mysql_auto_reconnect => 1,
                                }
                            );
my $redis = Redis->new;

print "load data\n";
my $users = $dbh->select_all("SELECT id FROM users");
my $memos = $dbh->select_all("SELECT * FROM memos ORDER BY id");

print "reset redis\n";
$redis->flushall;

print "trans ".scalar(@$memos)." memos\n";
for my $memo (@$memos) {
    print $memo->{id},"\n" if !($memo->{id}%100);
    my $title = (split(/\r?\n/, $memo->{content}, 2))[0];

    delete $memo->{updated_at};

    $memo->{content_html} = markdown($memo->{content});
    delete $memo->{content};
    my $json_memo = encode_json($memo);
    $redis->rpush('memos', $json_memo);

    $memo->{title} = $title;
    delete $memo->{content_html};
    $json_memo = encode_json($memo);

    $redis->rpush("user_memos_".$memo->{user}, $json_memo);
    if (!$memo->{is_private}) {
        $redis->rpush("public_memos", $json_memo);
    }
}
$dbh->query("UPDATE seq_memo SET id=?", $memos->[-1]->{id});
$redis->set('seq_memo', $memos->[-1]->{id});

print "pub len: ", $redis->llen("public_memos"), "\n";

my $elapsed_time = time()-$start;
print "initialize done ($elapsed_time sec)\n";

