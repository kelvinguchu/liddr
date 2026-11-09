package main

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
)

// fakeBucket stands in for Google Cloud Storage, the real client being under test.
type fakeBucket struct {
	mu      sync.Mutex
	objects map[string]fakeObject
}

type fakeObject struct {
	contentType string
	data        []byte
}

func (b *fakeBucket) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	b.mu.Lock()
	defer b.mu.Unlock()
	switch r.Method {
	case http.MethodPut:
		data, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "bad body", http.StatusBadRequest)
			return
		}
		b.objects[r.URL.Path] = fakeObject{contentType: r.Header.Get("Content-Type"), data: data}
	case http.MethodHead, http.MethodGet:
		object, ok := b.objects[r.URL.Path]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", object.contentType)
		w.Header().Set("Content-Length", strconv.Itoa(len(object.data)))
		if r.Method == http.MethodGet {
			_, _ = w.Write(object.data)
		}
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

// fakeClamd answers the INSTREAM protocol. Files containing EICAR are infected.
func fakeClamd(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	var wg sync.WaitGroup
	wg.Go(func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			answerClamd(conn)
		}
	})
	t.Cleanup(func() {
		_ = listener.Close()
		wg.Wait()
	})
	return listener.Addr().String()
}

func answerClamd(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	if _, err := io.ReadFull(conn, make([]byte, len("zINSTREAM\x00"))); err != nil {
		return
	}
	var body bytes.Buffer
	for {
		var size uint32
		if err := binary.Read(conn, binary.BigEndian, &size); err != nil || size == 0 {
			break
		}
		if _, err := io.CopyN(&body, conn, int64(size)); err != nil {
			return
		}
	}
	reply := "stream: OK\x00"
	if bytes.Contains(body.Bytes(), []byte("EICAR")) {
		reply = "stream: Eicar-Test-Signature FOUND\x00"
	}
	_, _ = conn.Write([]byte(reply))
}

func serviceAccountJSON(t *testing.T) string {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	account, err := json.Marshal(map[string]string{
		"client_email": "signer@test.iam.gserviceaccount.com",
		"private_key":  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
	})
	if err != nil {
		t.Fatalf("marshal account: %v", err)
	}
	return string(account)
}

type verificationWorld struct {
	baseURL string
	stub    *smsStub
	db      string
	bucket  *fakeBucket
	keys    map[string]string
}

// overwrite replaces an uploaded object, as a client holding the signed URL could.
func (w verificationWorld) overwrite(t *testing.T, uploadID string, content []byte) {
	t.Helper()
	w.bucket.mu.Lock()
	defer w.bucket.mu.Unlock()
	path, ok := w.keys[uploadID]
	if !ok {
		t.Fatalf("unknown upload %s", uploadID)
	}
	object := w.bucket.objects[path]
	object.data = content
	w.bucket.objects[path] = object
}

func startVerificationWorld(t *testing.T, databaseURL string, stub *smsStub) verificationWorld {
	t.Helper()
	provider := httptest.NewServer(stub)
	t.Cleanup(provider.Close)
	store := &fakeBucket{objects: map[string]fakeObject{}}
	bucket := httptest.NewServer(store)
	t.Cleanup(bucket.Close)
	google := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"routes":[{"distanceMeters":5000,"duration":"900s","polyline":{"encodedPolyline":"x"}}]}`))
	}))
	t.Cleanup(google.Close)
	baseURL, _ := startServerWithEnv(t, databaseURL, provider.URL, google.URL, map[string]string{
		"GCS_BUCKET":               "test-bucket",
		"GCS_BASE_URL":             bucket.URL,
		"GCS_SERVICE_ACCOUNT_JSON": serviceAccountJSON(t),
		"CLAMAV_ADDR":              fakeClamd(t),
	})
	return verificationWorld{baseURL: baseURL, stub: stub, db: databaseURL, bucket: store, keys: map[string]string{}}
}

// uploadFile asks for a signed URL and uploads content through it. It returns
// the upload id.
func (w verificationWorld) uploadFile(t *testing.T, token, documentType string, content []byte) string {
	t.Helper()
	prepared := send(t, http.MethodPost, w.baseURL+"/v1/verification/uploads", token, map[string]any{
		"document_type": documentType, "content_type": "image/jpeg", "size_bytes": len(content),
	})
	if prepared.status != http.StatusCreated {
		t.Fatalf("prepare upload = %d %v", prepared.status, prepared.body)
	}
	target, _ := prepared.body["upload_url"].(string)
	req, err := http.NewRequestWithContext(t.Context(), http.MethodPut, target, bytes.NewReader(content))
	if err != nil {
		t.Fatalf("build put: %v", err)
	}
	headers, _ := prepared.body["headers"].(map[string]any)
	for name, value := range headers {
		text, _ := value.(string)
		req.Header.Set(name, text)
	}
	client := http.Client{Timeout: testTimeout, Transport: &http.Transport{DisableKeepAlives: true}}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("put file: %v", err)
	}
	_ = resp.Body.Close() // Only the status matters.
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("put file = %d", resp.StatusCode)
	}
	id, _ := prepared.body["upload_id"].(string)
	w.keys[id] = req.URL.Path
	return id
}
