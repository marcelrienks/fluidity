package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"log"
	"math/big"
	"net"
	"os"
	"regexp"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

// CASignRequest represents the incoming CSR signing request
type CASignRequest struct {
	CSR string `json:"csr"` // PEM-encoded CSR
}

// CASignResponse represents the response from the CA Lambda
type CASignResponse struct {
	Certificate string `json:"certificate,omitempty"` // PEM-encoded signed certificate
	Error       string `json:"error,omitempty"`
}

// CAConfig holds the CA configuration
type CAConfig struct {
	caCert *x509.Certificate
	caKey  *rsa.PrivateKey
}

var caConfig *CAConfig

var (
	// arnRegex validates AWS ARN format
	arnRegex = regexp.MustCompile(`^arn:aws:[a-z0-9\-]+:[a-z0-9\-]*:[0-9]{12}:.+`)
	// ipv4Regex validates IPv4 address format
	ipv4Regex = regexp.MustCompile(`^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$`)
)

func init() {
	// Only initialize CA if not in test mode
	if os.Getenv("SKIP_CA_INIT") == "" {
		var err error
		caConfig, err = initializeCA()
		if err != nil {
			log.Fatalf("Failed to initialize CA: %v", err)
		}
	}
}

// initializeCA loads the CA certificate and key from AWS Secrets Manager
func initializeCA() (*CAConfig, error) {
	secretName := os.Getenv("CA_SECRET_NAME")
	if secretName == "" {
		return nil, fmt.Errorf("CA_SECRET_NAME environment variable not set")
	}

	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		return nil, fmt.Errorf("failed to load AWS config: %w", err)
	}

	client := secretsmanager.NewFromConfig(cfg)

	result, err := client.GetSecretValue(context.Background(), &secretsmanager.GetSecretValueInput{
		SecretId: &secretName,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to retrieve secret: %w", err)
	}

	var secret struct {
		CACert string `json:"ca_cert"`
		CAKey  string `json:"ca_key"`
	}

	if err := json.Unmarshal([]byte(*result.SecretString), &secret); err != nil {
		return nil, fmt.Errorf("failed to parse secret: %w", err)
	}

	// Parse CA certificate
	caCertBlock, _ := pem.Decode([]byte(secret.CACert))
	if caCertBlock == nil {
		return nil, fmt.Errorf("failed to decode CA certificate PEM")
	}

	caCert, err := x509.ParseCertificate(caCertBlock.Bytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse CA certificate: %w", err)
	}

	// Parse CA key
	caKeyBlock, _ := pem.Decode([]byte(secret.CAKey))
	if caKeyBlock == nil {
		return nil, fmt.Errorf("failed to decode CA key PEM")
	}

	caKey, err := x509.ParsePKCS1PrivateKey(caKeyBlock.Bytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse CA key: %w", err)
	}

	log.Printf("CA initialized: Subject=%s, NotAfter=%s", caCert.Subject.CommonName, caCert.NotAfter)

	return &CAConfig{
		caCert: caCert,
		caKey:  caKey,
	}, nil
}

// handleRequest processes the CSR signing request
func handleRequest(ctx context.Context, request events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	var csrReq CASignRequest
	if err := json.Unmarshal([]byte(request.Body), &csrReq); err != nil {
		return errorResponse(400, "Invalid request body")
	}

	if csrReq.CSR == "" {
		return errorResponse(400, "CSR not provided")
	}

	// Parse and validate CSR
	csr, err := parseAndValidateCSR(csrReq.CSR)
	if err != nil {
		return errorResponse(400, fmt.Sprintf("Invalid CSR: %v", err))
	}

	// Sign the certificate
	certPEM, err := signCSR(csr, caConfig)
	if err != nil {
		return errorResponse(500, fmt.Sprintf("Failed to sign certificate: %v", err))
	}

	resp := CASignResponse{
		Certificate: string(certPEM),
	}

	respBytes, _ := json.Marshal(resp)
	return events.APIGatewayProxyResponse{
		StatusCode: 200,
		Body:       string(respBytes),
		Headers: map[string]string{
			"Content-Type": "application/json",
		},
	}, nil
}

// parseAndValidateCSR parses a PEM-encoded CSR and validates it
func parseAndValidateCSR(csrPEM string) (*x509.CertificateRequest, error) {
	block, _ := pem.Decode([]byte(csrPEM))
	if block == nil {
		return nil, fmt.Errorf("failed to decode CSR PEM")
	}

	csr, err := x509.ParseCertificateRequest(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse CSR: %w", err)
	}

	// Verify CSR signature
	if err := csr.CheckSignature(); err != nil {
		return nil, fmt.Errorf("CSR signature verification failed: %w", err)
	}

	// Validate Common Name - accept either legacy format or ARN format
	cn := csr.Subject.CommonName
	isLegacyCN := cn == "fluidity-client" || cn == "fluidity-server"
	isARN := arnRegex.MatchString(cn)

	if !isLegacyCN && !isARN {
		return nil, fmt.Errorf("invalid Common Name: %s (must be 'fluidity-client', 'fluidity-server', or valid AWS ARN)", cn)
	}

	if isARN {
		log.Printf("Validating ARN-based certificate: CN=%s", cn)
	}

	// Validate IP addresses are present
	if len(csr.IPAddresses) == 0 {
		return nil, fmt.Errorf("CSR must contain at least one IP address")
	}

	// Validate all IP addresses
	for _, ip := range csr.IPAddresses {
		ipStr := ip.String()
		// Check if it's a valid IPv4 address
		if !ipv4Regex.MatchString(ipStr) {
			return nil, fmt.Errorf("invalid IPv4 address in SAN: %s", ipStr)
		}
		// Double-check with net.ParseIP
		if parsedIP := net.ParseIP(ipStr); parsedIP == nil {
			return nil, fmt.Errorf("failed to parse IP address in SAN: %s", ipStr)
		}
	}

	log.Printf("CSR validated: CN=%s, IPAddresses=%d", cn, len(csr.IPAddresses))

	return csr, nil
}

// signCSR signs a CSR and returns the signed certificate
func signCSR(csr *x509.CertificateRequest, caConfig *CAConfig) ([]byte, error) {
	// Create certificate template
	serialNumber, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, fmt.Errorf("failed to generate serial number: %w", err)
	}

	certTemplate := x509.Certificate{
		SerialNumber: serialNumber,
		Subject:      csr.Subject,
		NotBefore:    time.Now(),
		NotAfter:     time.Now().AddDate(1, 0, 0), // 1-year validity
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		IPAddresses:  csr.IPAddresses,
	}

	// Sign the certificate
	certBytes, err := x509.CreateCertificate(
		rand.Reader,
		&certTemplate,
		caConfig.caCert,
		csr.PublicKey,
		caConfig.caKey,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create certificate: %w", err)
	}

	// Encode to PEM
	certPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: certBytes,
	})

	log.Printf("Signed certificate: CN=%s, SerialNumber=%s, NotAfter=%s, IPAddresses=%d",
		csr.Subject.CommonName, serialNumber, certTemplate.NotAfter, len(csr.IPAddresses))

	return certPEM, nil
}

// errorResponse creates an error response
func errorResponse(statusCode int, message string) (events.APIGatewayProxyResponse, error) {
	resp := CASignResponse{
		Error: message,
	}
	respBytes, _ := json.Marshal(resp)
	return events.APIGatewayProxyResponse{
		StatusCode: statusCode,
		Body:       string(respBytes),
		Headers: map[string]string{
			"Content-Type": "application/json",
		},
	}, nil
}

func main() {
	lambda.Start(handleRequest)
}
