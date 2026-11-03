use crate::error::TlsError;
use crate::pki::{ClientAuth, Identity, RootPki, TlsSessions};
use rustls::client::Resumption;
use rustls::crypto::aws_lc_rs;
use rustls::server::{ClientHello, ResolvesServerCert, WebPkiClientVerifier};
use rustls::sign::CertifiedKey;
use rustls::{ClientConfig, ServerConfig};
use rustls_pki_types::{CertificateDer, ServerName};
use std::fmt;
use std::sync::Arc;

pub struct ClientOptions {
    pub roots: RootPki,
    /// Presented when the server asks.
    pub identity: Option<Identity>,
    /// ALPN protocol names in preference order; empty offers none.
    pub alpn: Vec<String>,
    /// Without one, no session is resumed.
    pub sessions: Option<TlsSessions>,
}

pub struct ServerOptions {
    /// At least one. The server uses the first whose certificate is valid for the client's SNI name;
    /// a client that sends no name, or a name none matches, gets the first (the client then refuses it
    /// with `NotValidForName`, which says more than an alert from the server would).
    pub identities: Vec<Identity>,
    pub client_auth: ClientAuth,
    pub alpn: Vec<String>,
}

/// An immutable client configuration; connections are made from it.
#[derive(Clone)]
pub struct TlsClient {
    pub(crate) config: Arc<ClientConfig>,
}

/// An immutable server configuration; connections are accepted from it.
#[derive(Clone)]
pub struct TlsServer {
    pub(crate) config: Arc<ServerConfig>,
}

fn alpn_bytes(names: &[String]) -> Vec<Vec<u8>> {
    names.iter().map(|n| n.as_bytes().to_vec()).collect()
}

impl TlsClient {
    pub fn new(options: ClientOptions) -> Result<TlsClient, TlsError> {
        let provider = Arc::new(aws_lc_rs::default_provider());
        let builder = ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .map_err(TlsError::from)?
            .with_root_certificates(options.roots.store.clone());
        let mut config = match options.identity {
            Some(identity) => builder
                .with_client_auth_cert(identity.chain.clone(), identity.key.clone_key())
                .map_err(|e| TlsError::BadKey(e.to_string()))?,
            None => builder.with_no_client_auth(),
        };
        config.alpn_protocols = alpn_bytes(&options.alpn);
        config.resumption = match options.sessions {
            Some(sessions) => Resumption::store(sessions.store),
            None => Resumption::disabled(),
        };
        Ok(TlsClient { config: Arc::new(config) })
    }
}

/// Picks the identity whose leaf is valid for the SNI name.
struct ByName {
    keys: Vec<Arc<CertifiedKey>>,
}

impl fmt::Debug for ByName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ByName").field("identities", &self.keys.len()).finish()
    }
}

impl ResolvesServerCert for ByName {
    fn resolve(&self, hello: ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        let named = hello.server_name().and_then(|name| ServerName::try_from(name).ok());
        let matching = named.and_then(|name| self.keys.iter().find(|key| valid_for(&key.cert[0], &name)));
        matching.or(self.keys.first()).cloned()
    }
}

fn valid_for(leaf: &CertificateDer<'_>, name: &ServerName<'_>) -> bool {
    webpki::EndEntityCert::try_from(leaf).is_ok_and(|cert| cert.verify_is_valid_for_subject_name(name).is_ok())
}

impl TlsServer {
    pub fn new(options: ServerOptions) -> Result<TlsServer, TlsError> {
        if options.identities.is_empty() {
            return Err(TlsError::BadCertificate("no identity".into()));
        }
        let provider = Arc::new(aws_lc_rs::default_provider());
        let builder =
            ServerConfig::builder_with_provider(provider.clone()).with_safe_default_protocol_versions().map_err(TlsError::from)?;
        let builder = match options.client_auth {
            ClientAuth::None => builder.with_no_client_auth(),
            ClientAuth::Require(roots) => {
                let verifier = WebPkiClientVerifier::builder_with_provider(roots.store.clone(), provider)
                    .build()
                    .map_err(|e| TlsError::BadCertificate(e.to_string()))?;
                builder.with_client_cert_verifier(verifier)
            }
        };
        let keys = options.identities.iter().map(|i| i.certified.clone()).collect();
        let mut config = builder.with_cert_resolver(Arc::new(ByName { keys }));
        config.alpn_protocols = alpn_bytes(&options.alpn);
        Ok(TlsServer { config: Arc::new(config) })
    }
}
