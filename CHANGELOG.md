# Changelog
All notable changes to this project will be documented in this file.

The format is based on semantic versioning (MAJOR.MINOR.PATCH).

---

## [v2.2.0] – Preparation for upcoming Projects
### Changed
- Improved compatibility with Debian-based distros
- dnscrypt-proxy updated to 2.1.18
- Added option to allow WAN-side SAT>IP servers for DVB streaming in nftables
- Rewrote SQM (tc) configuration to also support per-queue scheduling

## [v2.1.0] – Initial Release
### Added
- Optimized sysctl.d kernel/network parameters for deterministic routing performance
- nftables firewall (IPv4/IPv6) with modular chain layout
- dhcpcd for WAN DHCP and IPv6 autoconfiguration
- dnscrypt-proxy as encrypted upstream DNS resolver
- dnsmasq for LAN DHCP/DNS with strict role separation
- chrony as NTP server for router and LAN clients
- Optional components:
  - SQM (tc) for bufferbloat mitigation
  - DDNS (ddclient) for dynamic DNS updates
  - LDAP (slapd) for centralized phonebook/VoIP directory services
- Example configuration templates and documentation

### Removed / Disabled
- NetworkManager disabled/removed, replaced by dhcpcd and dnsmasq
- systemd-resolved disabled, replaced by dnsmasq and dnscrypt-proxy
- UFW (uncomplicated firewall) disabled, replaced by nftables

### Notes
- This is the first published version of the project.
