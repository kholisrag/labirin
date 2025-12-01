#!/bin/bash
# Debug script for 1Panel SSL uploader
# Run this on the target host to diagnose upload issues

echo "1Panel SSL Uploader - Troubleshooting"
echo "======================================"
echo ""

# Check if script exists
echo "1. Checking if uploader script exists..."
if [ -f ~/.acme/scripts/1panel-ssl-uploader.sh ]; then
    echo "   ✓ Script found: ~/.acme/scripts/1panel-ssl-uploader.sh"
    ls -lh ~/.acme/scripts/1panel-ssl-uploader.sh
else
    echo "   ✗ Script NOT found"
    echo "   Run: ansible-playbook acme-cert-updater.yaml"
    exit 1
fi
echo ""

# Check certificate files
echo "2. Checking certificate files..."
SCRIPT_CERT_DIR=$(grep '^CERT_DIR=' ~/.acme/scripts/1panel-ssl-uploader.sh | cut -d'"' -f2)
echo "   Certificate directory from script: $SCRIPT_CERT_DIR"

if [ -d "$SCRIPT_CERT_DIR" ]; then
    echo "   ✓ Directory exists"
    echo "   Contents:"
    ls -lh "$SCRIPT_CERT_DIR"
    
    if [ -f "$SCRIPT_CERT_DIR/key.pem" ] && [ -f "$SCRIPT_CERT_DIR/fullchain.pem" ]; then
        echo "   ✓ Required certificate files exist"
    else
        echo "   ✗ Missing key.pem or fullchain.pem"
    fi
else
    echo "   ✗ Directory does not exist: $SCRIPT_CERT_DIR"
fi
echo ""

# Check 1Panel service
echo "3. Checking 1Panel service..."
if systemctl is-active --quiet 1panel 2>/dev/null; then
    echo "   ✓ 1Panel service is running"
elif command -v 1pctl &>/dev/null; then
    STATUS=$(1pctl status 2>&1)
    echo "   1Panel status: $STATUS"
else
    echo "   ⚠ Cannot determine 1Panel status"
fi
echo ""

# Extract configuration from script
echo "4. Checking script configuration..."
UPLOAD_URL=$(grep '^UPLOAD_URL=' ~/.acme/scripts/1panel-ssl-uploader.sh | cut -d'"' -f2)
SSL_ID=$(grep '^SSL_ID=' ~/.acme/scripts/1panel-ssl-uploader.sh | cut -d'=' -f2)
echo "   Upload URL: $UPLOAD_URL"
echo "   SSL ID: $SSL_ID"
echo ""

# Test network connectivity
echo "5. Testing network connectivity..."
if [ -n "$UPLOAD_URL" ]; then
    BASE_URL=$(echo "$UPLOAD_URL" | sed 's|/api/.*||')
    echo "   Testing connection to: $BASE_URL"
    
    if curl -k -s -f -m 5 "$BASE_URL" > /dev/null 2>&1; then
        echo "   ✓ Can reach 1Panel"
    else
        HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" -m 5 "$BASE_URL" 2>/dev/null)
        if [ -n "$HTTP_CODE" ]; then
            echo "   ⚠ Got HTTP $HTTP_CODE from $BASE_URL"
        else
            echo "   ✗ Cannot reach 1Panel at $BASE_URL"
            echo "   Check if 1Panel is running and accessible"
        fi
    fi
else
    echo "   ✗ Could not extract UPLOAD_URL from script"
fi
echo ""

# Check for required tools
echo "6. Checking required tools..."
for tool in curl awk sed md5sum openssl; do
    if command -v $tool &>/dev/null; then
        echo "   ✓ $tool"
    else
        echo "   ✗ $tool (missing)"
    fi
done

# Check md5 for macOS
if ! command -v md5sum &>/dev/null && command -v md5 &>/dev/null; then
    echo "   ✓ md5 (macOS alternative)"
fi
echo ""

# Check logs
echo "7. Checking recent logs..."
if [ -f ~/.acme/scripts/upload.log ]; then
    echo "   Last 10 lines of upload.log:"
    tail -10 ~/.acme/scripts/upload.log | sed 's/^/   /'
else
    echo "   ⚠ No log file yet (upload.log)"
fi
echo ""

# Test token generation
echo "8. Testing token generation..."
API_KEY=$(grep '^API_KEY=' ~/.acme/scripts/1panel-ssl-uploader.sh | cut -d'"' -f2)
if [ -n "$API_KEY" ] && [ "$API_KEY" != "your-api-key-from-vault" ]; then
    TIMESTAMP=$(date +%s)
    TOKEN_STRING="1panel${API_KEY}${TIMESTAMP}"
    if command -v md5sum &>/dev/null; then
        TOKEN=$(echo -n "$TOKEN_STRING" | md5sum | awk '{print $1}')
        echo "   ✓ Token generation works (md5sum)"
        echo "   Sample token: ${TOKEN:0:10}... (truncated)"
    elif command -v md5 &>/dev/null; then
        TOKEN=$(echo -n "$TOKEN_STRING" | md5)
        echo "   ✓ Token generation works (md5)"
        echo "   Sample token: ${TOKEN:0:10}... (truncated)"
    else
        echo "   ✗ No md5sum or md5 command found"
    fi
else
    echo "   ⚠ API key not configured or still using placeholder"
fi
echo ""

echo "9. Suggested actions:"
echo ""
if [ ! -f "$SCRIPT_CERT_DIR/key.pem" ] || [ ! -f "$SCRIPT_CERT_DIR/fullchain.pem" ]; then
    echo "   • Wait for OPNsense to create certificates, or manually test with existing certs"
fi
echo "   • Check upload.log for detailed error messages"
echo "   • Verify API key in vault.yaml is correct"
echo "   • Ensure 1Panel is accessible from this host"
echo "   • Try running the script manually: ~/.acme/scripts/1panel-ssl-uploader.sh"
echo ""
