// origine:@std/dns/presets. Type-checked only, never run.
import type { Api } from '@origine/types';
import { presets } from 'origine:@std/dns/presets';

export async function main(api: Api, pem: Uint8Array): Promise<void> {
  const io = api.io.create();
  const resolver = api.dns.resolver(io, {
    servers: [presets.cloudflare.https(), presets.quad9.tls(), presets.google.udp(), presets.adguard.tcp()],
    roots: api.tls.RootPki.fromPem(pem),
    dnssec: 'off',
    timeout: 2000,
    tries: 2,
  });
  const name: string = presets.cloudflareFamily.name;
  const count: number = presets.cloudflareMalware.servers.length;
  void [resolver, name, count];

  // @ts-expect-error there is no such provider
  presets.opendns;
  // @ts-expect-error presets are data: they cannot be changed
  presets.google = presets.quad9;
  // @ts-expect-error a preset has no quic method yet
  presets.google.quic();
}
