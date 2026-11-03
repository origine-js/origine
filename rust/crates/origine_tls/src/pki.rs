use crate::error::TlsError;
use rustls::RootCertStore;
use rustls::client::ClientSessionMemoryCache;
use rustls::client::ClientSessionStore;
use rustls::crypto::aws_lc_rs;
use rustls::sign::CertifiedKey;
use rustls_pki_types::pem::PemObject;
use rustls_pki_types::{CertificateDer, PrivateKeyDer};
use std::sync::Arc;

/// The certificate authorities a peer is checked against. Cheap to clone.
#[derive(Clone)]
pub struct RootPki {
    pub(crate) store: Arc<RootCertStore>,
}

impl RootPki {
    /// The Mozilla root program, as compiled into the binary (webpki-roots).
    pub fn bundled() -> RootPki {
        RootPki { store: Arc::new(RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned())) }
    }

    /// Every certificate of a PEM bundle; at least one is required.
    pub fn from_pem(pem: &[u8]) -> Result<RootPki, TlsError> {
        let certs =
            CertificateDer::pem_slice_iter(pem).collect::<Result<Vec<_>, _>>().map_err(|e| TlsError::BadCertificate(e.to_string()))?;
        RootPki::from_certs(certs)
    }

    /// Each item is one DER certificate; at least one is required.
    pub fn from_der<C: AsRef<[u8]>>(certs: &[C]) -> Result<RootPki, TlsError> {
        RootPki::from_certs(certs.iter().map(|c| CertificateDer::from(c.as_ref().to_vec())).collect())
    }

    fn from_certs(certs: Vec<CertificateDer<'static>>) -> Result<RootPki, TlsError> {
        if certs.is_empty() {
            return Err(TlsError::BadCertificate("no certificate".into()));
        }
        let mut store = RootCertStore::empty();
        for cert in certs {
            store.add(cert).map_err(|e| TlsError::BadCertificate(e.to_string()))?;
        }
        Ok(RootPki { store: Arc::new(store) })
    }

    /// How many authorities this set holds.
    pub fn len(&self) -> usize {
        self.store.roots.len()
    }

    pub fn is_empty(&self) -> bool {
        self.store.roots.is_empty()
    }
}

/// A certificate chain (leaf first) with the private key of its leaf, checked against each other.
#[derive(Clone)]
pub struct Identity {
    pub(crate) chain: Vec<CertificateDer<'static>>,
    pub(crate) key: Arc<PrivateKeyDer<'static>>,
    pub(crate) certified: Arc<CertifiedKey>,
}

impl Identity {
    pub fn from_pem(cert_pem: &[u8], key_pem: &[u8]) -> Result<Identity, TlsError> {
        let chain =
            CertificateDer::pem_slice_iter(cert_pem).collect::<Result<Vec<_>, _>>().map_err(|e| TlsError::BadCertificate(e.to_string()))?;
        let key = PrivateKeyDer::from_pem_slice(key_pem).map_err(|e| TlsError::BadKey(e.to_string()))?;
        Identity::new(chain, key)
    }

    /// `chain` is DER certificates, leaf first; `key` is a PKCS#8, PKCS#1 or SEC1 DER private key.
    pub fn from_der<C: AsRef<[u8]>>(chain: &[C], key: &[u8]) -> Result<Identity, TlsError> {
        let chain = chain.iter().map(|c| CertificateDer::from(c.as_ref().to_vec())).collect();
        let key = PrivateKeyDer::try_from(key.to_vec()).map_err(|e| TlsError::BadKey(e.to_string()))?;
        Identity::new(chain, key)
    }

    fn new(chain: Vec<CertificateDer<'static>>, key: PrivateKeyDer<'static>) -> Result<Identity, TlsError> {
        if chain.is_empty() {
            return Err(TlsError::BadCertificate("no certificate".into()));
        }
        let signing = aws_lc_rs::sign::any_supported_type(&key).map_err(|e| TlsError::BadKey(e.to_string()))?;
        let certified = CertifiedKey::new(chain.clone(), signing);
        certified.keys_match().map_err(|e| TlsError::BadKey(e.to_string()))?;
        Ok(Identity { chain, key: Arc::new(key), certified: Arc::new(certified) })
    }
}

/// Whether a server asks the client for a certificate, and which authorities it accepts.
#[derive(Clone)]
pub enum ClientAuth {
    None,
    Require(RootPki),
}

impl ClientAuth {
    pub fn none() -> ClientAuth {
        ClientAuth::None
    }

    pub fn require(roots: RootPki) -> ClientAuth {
        ClientAuth::Require(roots)
    }
}

/// The client-side resumption cache. Passing one to a client is what turns resumption on.
#[derive(Clone)]
pub struct TlsSessions {
    pub(crate) store: Arc<dyn ClientSessionStore>,
}

impl TlsSessions {
    /// Remembers at most `limit` server names.
    pub fn create(limit: usize) -> TlsSessions {
        TlsSessions { store: Arc::new(ClientSessionMemoryCache::new(limit)) }
    }
}
