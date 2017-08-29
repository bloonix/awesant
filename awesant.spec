Summary: Awesant is a log shipper for logstash.
Name: awesant
Version: 0.23
Release: 1%{?dist}
License: distributable
Group: System Environment/Daemons
Distribution: RHEL and CentOS
URL: http://download.bloonix.de/

Packager: Jonny Schulz <js@bloonix.de>
Vendor: Bloonix

BuildArch: noarch
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-%(%{__id_u} -n)

Source0: http://download.bloonix.de/sources/%{name}-%{version}.tar.gz
Requires: perl
Requires: perl(Class::Accessor)
Requires: perl(Digest::MD5)
Requires: perl(IO::Socket)
Requires: perl(IO::Select)
Requires: perl(JSON)
Requires: perl(Log::Handler)
Requires: perl(Params::Validate)
Requires: perl(Sys::Hostname)
Requires: perl(Time::HiRes)
Requires: perl-JSON-XS
AutoReqProv: no

%define with_systemd 0
%define initdir %{_sysconfdir}/rc.d/init.d
%define confdir %{_sysconfdir}/awesant
%define logrdir %{_sysconfdir}/logrotate.d
%define logdir %{_var}/log/awesant
%define libdir %{_var}/lib/awesant
%define defaults %{_sysconfdir}/sysconfig

%description
Awesant is a log shipper for logstash.

%prep
%setup -q -n %{name}-%{version}

%build
%{__perl} Configure.PL --prefix /usr --initdir %{initdir} --without-perl --build-package
%{__make}
cd perl;
%{__perl} Build.PL installdirs=vendor
%{__perl} Build

%install
rm -rf %{buildroot}
%{__make} install DESTDIR=%{buildroot}
mkdir -p %{buildroot}%{libdir}
mkdir -p %{buildroot}%{logdir}
install -D -m 644 etc/defaults/awesant-agent %{buildroot}%{defaults}/awesant-agent
install -D -m 644 etc/logrotate.d/awesant %{buildroot}%{logrdir}/awesant

%if %{?with_systemd}
install -p -D -m 0644 etc/systemd/awesant-agent.service %{buildroot}%{_unitdir}/awesant-agent.service
%endif

install -p -D -m 0755 etc/init.d/awesant-agent %{buildroot}%{initdir}/awesant-agent

cd perl;
%{__perl} Build install destdir=%{buildroot} create_packlist=0
find %{buildroot} -name .packlist -exec %{__rm} {} \;

%post
true

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root)

%{_bindir}/awesant
%{_bindir}/awesant-create-cert

%dir %attr(0750, root, root) %{libdir}
%dir %attr(0750, root, root) %{logdir}
%dir %attr(0750, root, root) %{confdir}
%config(noreplace) %attr(0640, root, root) %{confdir}/agent.conf
%config(noreplace) %attr(0640, root, root) %{logrdir}/awesant
%config(noreplace) %attr(0640, root, root) %{defaults}/awesant-agent

%if %{?with_systemd}
%{_unitdir}/awesant-agent.service
%endif
%{initdir}/awesant-agent

%dir %{perl_vendorlib}/Awesant/
%dir %{perl_vendorlib}/Awesant/Input
%dir %{perl_vendorlib}/Awesant/Output
%{perl_vendorlib}/Awesant/*.pm
%{perl_vendorlib}/Awesant/Input/*.pm
%{perl_vendorlib}/Awesant/Output/*.pm
%{_mandir}/man?/Awesant::*

%changelog
* Tue Aug 29 2017 Jonny Schulz <js@bloonix.de> - 0.23-1
- Added feature multiline for inputs.
* Fri Aug 12 2016 Jonny Schulz <js@bloonix.de> - 0.22-1
- Fixed: determine if systemctl is in use.
* Fri Nov 06 2015 Jonny Schulz <js@bloonix.de> - 0.21-1
- Fixed: force the installation of the SysVinit script on systemd
  based distributions for backward compability.
* Thu Jul 09 2015 Jonny Schulz <js@bloonix.de> - 0.20-1
- Fixed systemd script name.
- Fixed debian postinst script.
* Thu Feb 19 2015 Jonny Schulz <js@bloonix.de> - 0.19-1
- Create a md5 sum for pos files and use the sum as file name
  to prevent too long file names.
* Fri Feb 13 2015 Jonny Schulz <js@bloonix.de> - 0.18-1
- Fixed creation of /var/lib/awesant.
* Fri Feb 13 2015 Jonny Schulz <js@bloonix.de> - 0.17-1
- Fixed file name generation of the pos file in Input/File.pm.
* Fri Feb 13 2015 Jonny Schulz <js@bloonix.de> - 0.16-1
- Startup failures are now logged into the logfile of awesant.
* Fri Feb 13 2015 Jonny Schulz <js@bloonix.de> - 0.15-1
- Fixed file name of pos file in /var/lib/awesant.
- Fixed screen output.
* Thu Sep 25 2014 Jonny Schulz <js@bloonix.de> - 0.14-1
- Added parameter 'grep' for Input/File.pm to skip events that
  does not match.
- Added the possibility to include files by pattern.
- Added awesant-agent.service for systemd.
- HangUp.pm is now used to fork awesant into the background.
* Fri Jan 17 2014 Jonny Schulz <js@bloonix.de> - 0.13-1
- Awesant is ready for the new logstash json schema.
- oldlogstashjson is now set to 'no' by default.
* Mon Dec 09 2013 Jonny Schulz <js@bloonix.de> - 0.12-1
- Implemented a failover mechanism for the redis output.
- The hostname can now be set in the configuration file.
- Added parameter milliseconds for @timestamp.
- Added parameter oldlogstashjson to switch between the old
  and new logstash json schema.
- Added parameter skip for Input/File.pm to skip events.
* Fri Aug 30 2013 Jonny Schulz <js@bloonix.de> - 0.11-1
- Added option ssl_verify_mode to Input/Socket.pm and Output/Socket.pm.
- Fixed dependencies of Awesant. Class::Accessor was missed.
- Modified the init script to make it runable on Solaris.
- It's now possible to use a wildcard for output types.
- Improved logrotate handling - the file input waits up to 10 seconds
  for new lines before close the rotated file.
- Fixed a typo in the init script that removes insserv warnings on Debian:
  'insserv: warning: script 'awesant-agent' missing LSB tags and overrides'
* Wed Jul 17 2013 Jonny Schulz <js@bloonix.de> - 0.10-1
- Added new output Rabbitmq.
- Fixed "undefined value as a hash reference ... line 371" if
  only one input exists that has workers configured.
* Fri Apr 19 2013 Jonny Schulz <js@bloonix.de> - 0.9-1
- Fixed: add_field does not work if format is set to json_event.
* Mon Apr 15 2013 Jonny Schulz <js@bloonix.de> - 0.8-1
- A lot of bug fixes and features implemented.
* Sun Feb 03 2013 Jonny Schulz <js@bloonix.net> - 0.7-1
- Some readability improvements.
- Added the debian specific directory with its control files to to build awesant for debian quickly.
* Thu Dec 06 2012 Jonny Schulz <js@bloonix.net> - 0.6-1
- Added a disconnect message to Output/Socket.pm.
- Added some benchmarking options to Agent.pm.
- Fixed "cat pidfile" in the init script.
- Added the new parameter 'format' for incoming messages.
- Added a input for tcp sockets.
- Now process groups are created for inputs that have the parameter 'workers' configured.
* Thu Nov 15 2012 Jonny Schulz <js@bloonix.net> - 0.4-1
- Implemented a extended add_field feature.
* Sun Nov 11 2012 Jonny Schulz <js@bloonix.net> - 0.3-1
- Fixed timestamp formatting.
- Modified an confusing error message.
- Some code improvements in Output/Redis.pm.
* Sun Nov 11 2012 Jonny Schulz <js@bloonix.net> - 0.2-1
- Fixed "Can't call method is_debug" in Output/Screen.pm.
- Added the feature that multiple types can be set for outputs.
- Deleted awesant.conf - this file will be build by make.
* Thu Nov 08 2012 Jonny Schulz <js@bloonix.net> - 0.1-1
- Initial package.
