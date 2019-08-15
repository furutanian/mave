FROM docker.io/furutanian/hyperestraier

LABEL 'maintainer=Furutanian <furutanian@gmail.com>'

ARG TZ
ARG http_proxy
ARG https_proxy

RUN set -x \
	&& dnf install -y \
		httpd \
		ruby \
		sudo \
		qdbm \
		ruby-qdbm \
		rubygems \
		ruby-devel \
		gcc \
		redhat-rpm-config \
		ncurses-devel \
		make \
		findutils \
		git \
		procps-ng \
		net-tools \
	&& rm -rf /var/cache/dnf/* \
	&& dnf clean all \
	&& gem install curses

# git clone mave しておくこと
COPY mave /var/www/html
RUN cat /var/www/html/dot.htaccess \
		| sed 's/\(Action.*rhtml-script\)\(.*maverick\)/\1 \//' \
		> /var/www/html/.htaccess

RUN mv /etc/httpd/conf/httpd.conf /etc/httpd/conf/httpd.conf.org \
	&& cat /etc/httpd/conf/httpd.conf.org \
		| sed '/^<Directory "\/var\/www\/html">/,/^</s/^\(\s*Options\).*/\1 All/' \
		| sed '/^<Directory "\/var\/www\/html">/,/^</s/^\(\s*AllowOverride\).*/\1 All/' \
		> /etc/httpd/conf/httpd.conf \
	&& diff -C 2 /etc/httpd/conf/httpd.conf.org /etc/httpd/conf/httpd.conf \
	|| echo '/etc/httpd/conf/httpd.conf changed.'
RUN systemctl enable httpd

EXPOSE 80

# Dockerfile 中の設定スクリプトを抽出するスクリプトを出力、実行
COPY Dockerfile .
RUN echo $'\
cat Dockerfile | sed -n \'/^##__BEGIN0/,/^##__END0/p\' | sed \'s/^#//\' > startup.sh\n\
cat Dockerfile | sed -n \'/^##__BEGIN1/,/^##__END1/p\' | sed \'s/^#//\' > pop.sh\n\
' > extract.sh && bash extract.sh

# docker-compose up の最後に実行される設定スクリプト
##__BEGIN0__startup.sh__
#
#	ln -fs ../usr/share/zoneinfo/$TZ /etc/localtime
#
#	mkdir -v -p /var/lib/pv/mave/conf
#	mkdir -v -p /var/lib/pv/mave/mave.mails
#
#	chown -v apache:apache /var/lib/pv/mave/mave.mails
#	if [ ! -e /var/lib/pv/mave/conf/mave.config ]; then
#		cat /var/www/html/mave.config.sample \
#			| sed 's!\(^@configs\[:ROOT_DIRECTORY\].*= \).*!\1"/var/lib/pv/mave/mave.mails"!' \
#			> /var/lib/pv/mave/conf/mave.config
#		diff -C 2 /var/www/html/mave.config.sample /var/lib/pv/mave/conf/mave.config
#	fi
#	ln -v -s /var/lib/pv/mave/conf/mave.config /var/www/html
#
#	mkdir -v -p /var/lib/pv/mave/mave.mails/Inbox
#	chown -v apache:apache /var/lib/pv/mave/mave.mails/Inbox
#	cd /var/lib/pv/mave/mave.mails/Inbox
#	find . -type f -name "*.eml" | sudo -u apache estcmd gather -cl -fm -cm casket -
#	estcmd search -vh -max 3 casket 'Linux'
#
#	cat /var/www/html/crontab.nomailto >> /var/www/html/crontab
#	cat /var/www/html/crontab.maverick >> /var/www/html/crontab
#	crontab /var/www/html/crontab
#
##	bash pop.sh &
#
##__END0__startup.sh__

##__BEGIN1__pop.sh__
#
#	cd /var/www/html
#	while true
#	do
#		date
#		sudo -u apache ./mave_fetch
#		sleep 600
#	done
#
##__END1__pop.sh__

