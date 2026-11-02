// `origine:@std/dns/presets`: well-known public resolvers as data, kept out of `DnsServer` on purpose. Each
// preset names a provider, lists its addresses (`servers`, IPv4 first) and has one method per transport the
// provider offers (`udp`, `tcp`, `tls`, `https`); a method makes the server with the public `DnsServer`
// constructors of the realm, so a preset is nothing a program could not write by hand. A transport a provider
// lacks has no method. Presets are never a default: `dns.resolver` always takes an explicit `servers`.
//
// The filtering providers (Cloudflare Malware and Family, AdGuard, Quad9) change answers on purpose: names they
// block resolve to nothing or to a block page address. Addresses and TLS names are the providers' published ones
// and are pinned by a test.
import { provided } from 'origine:@internal/handles';

const freeze = Object.freeze;

const classes = () => provided('dns/classes');

const preset = (name, { v4, v6, tls, https }) => {
  let servers;
  const list = () => (servers ??= freeze([...v4, ...v6].map(text => classes().IpAddr.parse(text))));
  const made = { name };
  Object.defineProperty(made, 'servers', { get: list, enumerable: true });
  // A fresh server each call: servers are frozen values, not shared state.
  made.udp = () => classes().DnsServer.udp(list());
  made.tcp = () => classes().DnsServer.tcp(list());
  if (tls !== undefined) made.tls = () => classes().DnsServer.tls(tls, list());
  if (https !== undefined) made.https = () => classes().DnsServer.https(https, list());
  return freeze(made);
};

/// The providers, by key. `presets.cloudflare.tls()` is `DnsServer.tls('one.one.one.one', presets.cloudflare.servers)`.
export const presets = freeze({
  cloudflare: preset('Cloudflare', {
    v4: ['1.1.1.1', '1.0.0.1'],
    v6: ['2606:4700:4700::1111', '2606:4700:4700::1001'],
    tls: 'one.one.one.one',
    https: 'https://cloudflare-dns.com/dns-query',
  }),
  /// Blocks known malware domains.
  cloudflareMalware: preset('Cloudflare Malware', {
    v4: ['1.1.1.2', '1.0.0.2'],
    v6: ['2606:4700:4700::1112', '2606:4700:4700::1002'],
    tls: 'security.cloudflare-dns.com',
    https: 'https://security.cloudflare-dns.com/dns-query',
  }),
  /// Blocks malware and adult content.
  cloudflareFamily: preset('Cloudflare Family', {
    v4: ['1.1.1.3', '1.0.0.3'],
    v6: ['2606:4700:4700::1113', '2606:4700:4700::1003'],
    tls: 'family.cloudflare-dns.com',
    https: 'https://family.cloudflare-dns.com/dns-query',
  }),
  /// AdGuard DNS in its default mode: blocks ads and trackers.
  adguard: preset('AdGuard', {
    v4: ['94.140.14.14', '94.140.15.15'],
    v6: ['2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff'],
    tls: 'dns.adguard-dns.com',
    https: 'https://dns.adguard-dns.com/dns-query',
  }),
  google: preset('Google', {
    v4: ['8.8.8.8', '8.8.4.4'],
    v6: ['2001:4860:4860::8888', '2001:4860:4860::8844'],
    tls: 'dns.google',
    https: 'https://dns.google/dns-query',
  }),
  /// Quad9's recommended service: blocks known malicious domains and validates DNSSEC.
  quad9: preset('Quad9', {
    v4: ['9.9.9.9', '149.112.112.112'],
    v6: ['2620:fe::fe', '2620:fe::9'],
    tls: 'dns.quad9.net',
    https: 'https://dns.quad9.net/dns-query',
  }),
});
