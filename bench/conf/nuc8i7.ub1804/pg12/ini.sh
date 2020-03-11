bdir=/data/m/pg

echo "stop and remove files"
bin/pg_ctl -D $bdir stop
rm -rf $bdir/*
rm -f logfile; touch logfile
killall mysqld mongod

if [ "$#" -ge 1 ]; then
    cp conf.diff.c${1} conf.diff
fi 

echo "init"
bin/initdb --data-checksums -D $bdir >& o.ini.1
mv $bdir/postgresql.conf $bdir/postgresql.conf.orig
cat $bdir/postgresql.conf.orig conf.diff > $bdir/postgresql.conf
bin/pg_ctl -D $bdir -l logfile start >& o.ini.2
sleep 5

echo "create db and users"
bin/createdb me
bin/psql me -c "create user root with superuser login password 'pw'"

bin/psql template1 -c 'create extension pgstattuple'
