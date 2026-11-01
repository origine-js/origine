// Positive cases and `@ts-expect-error` negatives for api.dns. Type-checked only, never run.
import type { Api, IpAddr } from "@origine/types";

export async function main(api: Api, pem: Uint8Array): Promise<void> {
  const { dns } = api;
  const io = api.io.create();
  const server = dns.SocketAddr.new(dns.IpAddr.v4(127, 0, 0, 1), 5353);
  const resolver = dns.resolver(io, {
    servers: [dns.DnsServer.udp([server]), dns.DnsServer.tcp([dns.IpAddr.parse("::1")]), dns.DnsServer.tls("dns.test", [server]), dns.DnsServer.system()],
    roots: api.tls.RootPki.fromPem(pem),
    dnssec: "off",
    timeout: 2000,
    tries: 2,
  });
  const addresses: IpAddr[] = await resolver.lookup("example.test", { family: "any" });
  const text: string = addresses[0]!.toString();
  const loopback: boolean = addresses[0]!.toCanonical().isLoopback();
  void [text, loopback];

  // @ts-expect-error every number is required: no hidden defaults
  dns.resolver(io, { servers: [], dnssec: "off" });
  // @ts-expect-error a family is required
  await resolver.lookup("example.test", {});
  // @ts-expect-error addresses are made by named constructors
  new dns.IpAddr();
  // @ts-expect-error servers are IpAddr or SocketAddr, not strings
  dns.DnsServer.udp(["127.0.0.1"]);
}
