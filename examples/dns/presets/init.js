// Run: zig build run -- examples/dns/presets/init.js   (or: zig-out/bin/origine examples/dns/presets/init.js)
// Presets are data: the public resolvers' addresses and names, each with a constructor per transport. Building one
// opens nothing, but a resolver reaches the servers only through the network ceiling, and by default only loopback
// is allowed: so a preset's resolver is refused with PermissionDenied. Options that have no default must be given:
// `dnssec: 'validate'` is not implemented yet, so it is refused.
//
// Prints (stderr):
//   quad9: Quad9, servers 9.9.9.9, 149.112.112.112, 2620:fe::fe, 2620:fe::9
//   quad9 over TLS: a DnsServer: true
//   resolver to quad9 by default: PermissionDenied (subject 9.9.9.9:53)
//   dnssec 'validate': Unsupported
import { presets } from 'origine:@std/dns/presets';
import { eprintln } from 'origine:@std/debug';

const outcome = async run => {
  try {
    await run();
    return 'ok';
  } catch (e) {
    return `${e.name}${e.subject ? ` (subject ${e.subject})` : ''}`;
  }
};

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const { quad9 } = presets;   // the DnsServer constructors are api.dns.DnsServer; a preset's method makes one with them
  eprintln(`quad9: ${quad9.name}, servers ${quad9.servers.map(String).join(', ')}`);
  eprintln(`quad9 over TLS: a DnsServer: ${quad9.tls() instanceof api.dns.DnsServer}`);

  const io = api.io.create({});
  try {
    const servers = quad9.udp();
    eprintln(`resolver to quad9 by default: ${await outcome(() => api.dns.resolver(io, { servers: [servers], dnssec: 'off', timeout: 2000, tries: 2 }))}`);
    eprintln(`dnssec 'validate': ${await outcome(() => api.dns.resolver(io, { servers: [servers], dnssec: 'validate', timeout: 2000, tries: 2 }))}`);
  } finally {
    await io.close();
  }
}
