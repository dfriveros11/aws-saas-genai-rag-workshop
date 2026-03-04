# Setup: SaaS and RAG Workshop (Windows — Cuenta propia)

Guía paso a paso para desplegar el workshop "SaaS and RAG: Maximizing Generative AI Value in Multi-Tenant Solutions" en una cuenta de AWS propia, desde Windows con WSL2.

Región: `us-west-2`

## Paso 1 — Instalar WSL2

Abrir PowerShell como Administrador:

```powershell
wsl --install
```

Esto instala WSL2 con Ubuntu por defecto. Reiniciar el equipo cuando lo pida. Al reiniciar, se abre una terminal de Ubuntu para crear usuario y contraseña.

Verificar:

```powershell
wsl --version
```

## Paso 2 — Instalar Docker Desktop

Descargar e instalar [Docker Desktop para Windows](https://www.docker.com/products/docker-desktop/). Durante la instalación, asegurarse de que la opción "Use WSL 2 based engine" esté habilitada.

Verificar desde WSL2:

```bash
docker --version
docker info
```

Si `docker` no se encuentra en WSL2, abrir Docker Desktop → Settings → Resources → WSL Integration → habilitar la distro de Ubuntu.

## Paso 3 — Instalar Node.js en WSL2

Desde la terminal de WSL2 (Ubuntu):

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
```

Verificar:

```bash
node --version
npm --version
```

## Paso 4 — Configurar AWS CLI en WSL2

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip
```

Configurar credenciales:

```bash
aws configure
```

Verificar:

```bash
aws sts get-caller-identity
```

## Paso 5 — Clonar el repositorio

Desde WSL2:

```bash
mkdir -p ~/workshop
cd ~/workshop
git clone https://github.com/dfriveros11/aws-saas-genai-rag-workshop.git
cd aws-saas-genai-rag-workshop
```

## Paso 6 — Instalar dependencias de CDK

```bash
cd cdk
npm install
cd ..
```

## Paso 7 — Bootstrap de CDK

Solo necesario la primera vez por cuenta/región:

```bash
export AWS_DEFAULT_REGION=us-west-2
npx cdk bootstrap
```

No se necesita `CDK_DOCKER=finch` en Windows — Docker Desktop es el runtime por defecto.

## Paso 8 — Reemplazar `deploy.sh`

El script original tiene un bug: no despliega el ControlPlaneStack antes del Application Plane, causando el error `No export named SbtEventBus found`.

Reemplazar el contenido completo de `scripts/deploy.sh`:

```bash
cat > scripts/deploy.sh << 'DEPLOY_EOF'
#!/bin/bash
set +e

CONTROL_PLANE_STACK="ControlPlaneStack"
BOOTSTRAP_STACK="saas-genai-workshop-bootstrap-template"
CORE_UTILS_STACK="saas-genai-workshop-core-utils-stack"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CDK_DIR="$SCRIPT_DIR/../cdk"
ROOT_DIR="$SCRIPT_DIR/.."

deploy_stack() {
    local STACK_NAME="$1"
    echo ""
    echo "=========================================="
    echo "Deploying: $STACK_NAME"
    echo "=========================================="

    cd "$CDK_DIR"
    npx cdk deploy "$STACK_NAME" --require-approval never \
        --concurrency 10 --asset-parallelism true --exclusively

    local EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        echo "ERROR: Failed to deploy $STACK_NAME. Aborting."
        exit $EXIT_CODE
    fi

    echo "✅ $STACK_NAME deployed successfully."
}

cleanup_rollback() {
    local STACK_NAME="$1"
    local STATUS
    STATUS=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].StackStatus" \
        --output text 2>/dev/null || echo "DOES_NOT_EXIST")

    if [ "$STATUS" == "ROLLBACK_COMPLETE" ]; then
        echo "⚠️  $STACK_NAME is in ROLLBACK_COMPLETE. Deleting before redeployment..."
        aws cloudformation delete-stack --stack-name "$STACK_NAME"
        aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
        echo "🗑️  $STACK_NAME deleted."
    fi
}

echo ""
echo "STEP 1: Checking ControlPlane export..."
CONTROL_PLANE_EXPORT=$(aws cloudformation list-exports \
    --query "Exports[?contains(Name, 'SbtEventBus')].Value" \
    --output text 2>/dev/null)

if [ -z "$CONTROL_PLANE_EXPORT" ] || [ "$CONTROL_PLANE_EXPORT" == "None" ]; then
    echo "ControlPlane export not found. Deploying $CONTROL_PLANE_STACK..."
    cleanup_rollback "$CONTROL_PLANE_STACK"
    deploy_stack "$CONTROL_PLANE_STACK"
else
    echo "✅ ControlPlane export already exists. Skipping."
fi

echo ""
echo "STEP 2: Deploying Core Utils Stack..."
cleanup_rollback "$CORE_UTILS_STACK"
deploy_stack "$CORE_UTILS_STACK"

echo ""
echo "STEP 3: Deploying Bootstrap Template (S3 + OpenSearch)..."
cleanup_rollback "$BOOTSTRAP_STACK"
deploy_stack "$BOOTSTRAP_STACK"

echo ""
echo "STEP 4: Looking up TenantSourceCodeS3Bucket..."
S3_BUCKET=$(aws cloudformation describe-stacks \
    --stack-name "$BOOTSTRAP_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='TenantSourceCodeS3Bucket'].OutputValue" \
    --output text 2>/dev/null)

if [ -z "$S3_BUCKET" ] || [ "$S3_BUCKET" == "None" ]; then
    echo "Bootstrap stack bucket not found. Searching all stacks..."
    ALL_STACKS=$(aws cloudformation list-stacks \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query "StackSummaries[].StackName" \
        --output text)
    for STACK in $ALL_STACKS; do
        BUCKET=$(aws cloudformation describe-stacks \
            --stack-name "$STACK" \
            --query "Stacks[0].Outputs[?OutputKey=='TenantSourceCodeS3Bucket'].OutputValue" \
            --output text 2>/dev/null)
        if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
            echo "Found TenantSourceCodeS3Bucket in stack: $STACK"
            S3_BUCKET="$BUCKET"
            break
        fi
    done
fi

if [ -z "$S3_BUCKET" ] || [ "$S3_BUCKET" == "None" ]; then
    echo "⚠️  WARNING: No S3 bucket found. Skipping code sync."
    echo "✅ All stacks deployed successfully."
    exit 0
fi

echo "S3 bucket: $S3_BUCKET"
cd "$ROOT_DIR"
echo "Uploading updated code..."
aws s3 sync "." "s3://$S3_BUCKET" \
    --exclude "cdk/cdk.out/*" \
    --exclude "cdk/node_modules/*" \
    --exclude ".git/*"

echo ""
echo "=========================================="
echo "✅ Full deployment completed successfully!"
echo "=========================================="
DEPLOY_EOF
chmod +x scripts/deploy.sh
```

El script despliega en orden: ControlPlaneStack, CoreUtils, Bootstrap, y sincroniza código a Amazon S3.

## Paso 9 — Completar los TODOs del código

### 9a — Tenant Provisioning Service

En `cdk/lib/tenant-template/tenant-provisioning/tenant_provisioning_service.py`, debajo del comentario `# TODO: Lab1 - Add provision tenant resources`, ya deben estar estas 3 líneas:

```python
__create_opensearch_serverless_tenant_index(tenant_id, kb_collection_endpoint_domain)
__create_s3_tenant_prefix(tenant_id, rule_name)
__create_tenant_knowledge_base(tenant_id, kb_collection_name, rule_name)
```

Si no están, agregarlas manualmente con la indentación correcta (8 espacios).

### 9b — Provision Tenant Script

En `scripts/provision-tenant.sh`, debajo del comentario `# TODO: Lab1 - Add tenant provisioning service`, ya debe estar esta línea:

```bash
tenant_provision_output=$(python3 lib/tenant-template/tenant-provisioning/tenant_provisioning_service.py --tenantid "$CDK_PARAM_TENANT_ID" 2>&1 > /dev/null && exit_code=$?) || exit_code=$?
check_error "$provision_name" $exit_code "$tenant_provision_output"
```

Si no está, agregarla manualmente.

### 9c — Fix ragService (imports + requirements)

El código original de `rag_service.py` importa desde `langchain.chains` y `langchain_community.retrievers`. Sin un `requirements.txt`, el Lambda no encuentra los módulos. Si se agregan las dependencias al `requirements.txt`, se duplican con las del `utilsLayer` y el paquete combinado supera el límite de 250 MB.

La solución es dejar el `requirements.txt` vacío y optimizar los imports para usar solo módulos disponibles en el layer.

#### 9c.1 — Dejar `requirements.txt` vacío

Crear `cdk/lib/tenant-template/services/ragService/requirements.txt`:

```text
# Dependencies provided by utilsLayer — do not duplicate here
```

#### 9c.2 — Optimizar imports en `rag_service.py`

En `cdk/lib/tenant-template/services/ragService/rag_service.py`, reemplazar los imports de langchain:

```python
# ANTES (no usar):
# from langchain_community.retrievers import AmazonKnowledgeBasesRetriever
# from langchain.chains import RetrievalQA

# DESPUÉS (correcto):
from langchain_aws.chat_models import ChatBedrockConverse
from langchain_core.prompts import ChatPromptTemplate
from langchain_aws.retrievers import AmazonKnowledgeBasesRetriever
from langchain_core.runnables import RunnablePassthrough
```

Usar `RunnablePassthrough` con una cadena LCEL en lugar de `RetrievalQA`.
