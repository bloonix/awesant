CONFIG=Makefile.config
SHELL := /bin/bash

include $(CONFIG)

default: build

build:
	cp etc/awesant/agent.conf.in etc/awesant/agent.conf; \
	sed -i "s!@@FILE@@!$(LOGDIR)/awesant/agent.log!" etc/awesant/agent.conf; \
	cp bin/awesant.in bin/awesant; \
	sed -i "s!@@PERL@@!$(PERL)!" bin/awesant; \
	sed -i "s!@@CONFIG@@!$(CONFDIR)/awesant/agent.conf!" bin/awesant; \
	sed -i "s!@@PIDFILE@@!$(RUNDIR)/awesant/agent.pid!" bin/awesant; \
	cp etc/init.d/awesant-agent.in etc/init.d/awesant-agent; \
	sed -i "s!@@DAEMON@@!$(PREFIX)/bin/awesant!" etc/init.d/awesant-agent; \
	sed -i "s!@@RUNDIR@@!$(RUNDIR)/awesant!" etc/init.d/awesant-agent; \
	sed -i "s!@@CONFIG@@!$(CONFDIR)/awesant/agent.conf!" etc/init.d/awesant-agent; \
	sed -i "s!@@CONFIG@@!$(LOGDIR)/awesant/agent.log!" etc/init.d/awesant-agent; \
	if test "$(WITHOUT_PERL)" = "0" ; then \
		$(PERL) perl/Build manifest; \
		if test "$(PERL_DESTDIR)" ; then \
	        set -e; cd perl; \
			$(PERL) Build.PL --installdirs $(PERL_INSTALLDIRS); \
		else \
	        set -e; cd perl; \
			$(PERL) Build.PL --installdirs $(PERL_INSTALLDIRS) --destdir $(PERL_DESTDIR); \
		fi; \
		$(PERL) Build; \
	fi;

test:
	if test "$(WITHOUT_PERL)" = "0" ; then \
		set -e; cd perl; \
		$(PERL) Build test; \
	fi;

install:
	# install the configuration
	if test ! -e "$(CONFDIR)/awesant" && test ! -L "$(CONFDIR)/awesant" ; then \
		./install-sh -d -m 0750 $(CONFDIR)/awesant; \
		./install-sh -c -m 0640 etc/awesant/agent.conf $(CONFDIR)/awesant/agent.conf; \
	fi;

	# create the logfile path
	if test ! -e "$(LOGDIR)/awesant" ; then \
		./install-sh -d -m 0750 $(LOGDIR)/awesant; \
	fi;

	# install the awesant agent
	if test ! -e "$(PREFIX)/bin" ; then \
		./install-sh -d -m 0755 $(PREFIX)/bin; \
	fi;

	./install-sh -c -m 0755 bin/awesant $(PREFIX)/bin/awesant
	./install-sh -c -m 0755 bin/awesant-create-cert $(PREFIX)/bin/awesant-create-cert

	# install the startup script
	if test ! -e "$(INITDIR)" ; then \
		./install-sh -d -m 0755 $(INITDIR); \
	fi;

	./install-sh -c -m 0755 etc/init.d/awesant-agent $(INITDIR)/awesant-agent;

	# install the awesant agent perl modules
	if test "$(WITHOUT_PERL)" = "0" ; then \
		set -e; cd perl; $(PERL) Build install; $(PERL) Build realclean; \
	fi;

clean:
	if test "$(WITHOUT_PERL)" = "0" ; then \
		cd perl; \
		if test -e "Build" ; then \
			$(PERL) Build realclean; \
		fi; \
		rm -f bin/awesant etc/init.d/awesant etc/awesant/agent.conf; \
	fi;
