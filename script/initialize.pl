use strict;
use warnings;
use utf8;
use DBIx::Sunny;
use Redis;
use JSON::XS;
use Text::Markdown::Discount qw/markdown/;
use MongoDB;

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

my $mongo = MongoDB::MongoClient->new;
my $mdb = $mongo->get_database('isucon3');

print "reset redis\n";
$redis->flushall;

print "reset mongo\n";
my $seq = $mdb->get_collection('seq');
$seq->remove;
my $memos = $mdb->get_collection('memos');
$memos->remove;
$memos->ensure_index({ user => 1, _id => 1 });
$memos->ensure_index({ user => 1, is_private => 1, _id => 1 });
my $public_memos = $mdb->get_collection('public_memos');
$public_memos->remove;

print "load data\n";
my $users = $dbh->select_all("SELECT id,username FROM users");
my %USERNAME_OF = map { $_->{id} => $_->{username} } @$users;
my $raw_memos = $dbh->select_all("SELECT * FROM memos ORDER BY id");

print "trans ".scalar(@$raw_memos)." memos\n";
for my $memo (@$raw_memos) {
    print $memo->{id},"\n" if !($memo->{id}%100);
    $memo->{_id} = $memo->{id};
    delete $memo->{id};
    $memo->{is_private} = int($memo->{is_private});
    $memo->{user} = int($memo->{user});

    $memo->{username} = $USERNAME_OF{$memo->{user}};
    my $title = (split(/\r?\n/, $memo->{content}, 2))[0];
    $memo->{title} = $title;

    delete $memo->{updated_at};

    $memo->{content_html} = markdown($memo->{content});
    delete $memo->{content};
    $memos->insert($memo);

    delete $memo->{content_html};
    $public_memos->insert($memo) unless $memo->{is_private};
}
$seq->insert({ _id => 'memo', seq => $raw_memos->[-1]->{_id} });

my $elapsed_time = time()-$start;
print "initialize done ($elapsed_time sec)\n";

