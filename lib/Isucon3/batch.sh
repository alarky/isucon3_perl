#!/bin/sh
echo "batch start" >> /tmp/batch.log
. /home/isucon/env.sh
echo "env done" >> /tmp/batch.log
/home/isucon/local/perl-5.18/bin/carton exec perl /home/isucon/webapp/perl/lib/Isucon3/batch.pl
