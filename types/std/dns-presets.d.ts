// `origine:@std/dns/presets`: well-known public resolvers as data, not part of `DnsServer`.
declare module 'origine:@std/dns/presets' {
  import type { DnsServer, IpAddr } from '@origine/types';

  /**
   * One provider. `udp` and `tcp` use port 53, `tls` port 853 and `https` port 443; each call makes a new
   * `DnsServer` with the realm's public constructors, so what it needs is what they need: `roots` in
   * `dns.resolver` for `tls` and `https`, and a `connect` rule of the embedder's network ceiling for
   * `servers` (these are public addresses: loopback is the only thing allowed by default).
   */
  export interface Preset {
    /** The provider's name. */
    readonly name: string;
    /** Its addresses, IPv4 first (frozen). */
    readonly servers: readonly IpAddr[];
    udp(): DnsServer;
    tcp(): DnsServer;
    /** DNS over TLS; the certificate must be valid for the provider's name (for example `one.one.one.one`). */
    tls(): DnsServer;
    /** DNS over HTTPS at the provider's `/dns-query`. */
    https(): DnsServer;
  }

  /**
   * Providers by key. A preset is never a default: `dns.resolver` always takes an explicit `servers`. The filtering
   * ones (`cloudflareMalware`, `cloudflareFamily`, `adguard`, `quad9`) change answers on purpose: names they block
   * resolve to nothing, or to an address of their own.
   */
  export const presets: {
    readonly cloudflare: Preset;
    /** Blocks known malware domains. */
    readonly cloudflareMalware: Preset;
    /** Blocks malware and adult content. */
    readonly cloudflareFamily: Preset;
    /** AdGuard DNS, default mode: blocks ads and trackers. */
    readonly adguard: Preset;
    readonly google: Preset;
    /** Quad9's recommended service: blocks known malicious domains. */
    readonly quad9: Preset;
  };
}
