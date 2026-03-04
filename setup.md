# Setup: SaaS and RAG Workshop (Cuenta propia)

Guía paso a paso para desplegar el workshop "SaaS and RAG: Maximizing Generative AI Value in Multi-Tenant Solutions" en una cuenta de AWS propia (sin Workshop Studio).

Región: `us-west-2`

## Paso 1 — Prerrequisitos del sistema

Instalar Node.js (para CDK) y Finch (container runtime):

```bash
brew install node
brew install finch
finch vm init
```

Verificar:

```bash
node --version
finch --version
```

## Paso 2 — Clonar el repositorio

```bash
mkdir -p ~/workshop
cd ~/workshop
git clone https://github.com/dfriveros11/aws-saas-genai-rag-workshop.git
cd aws-saas-genai-rag-workshop
```

## Paso 3 — Instalar dependencias de CDK

```bash
cd cdk
npm install
cd ..
```

## Paso 4 — Bootstrap de CDK

Solo necesario la primera vez por cuenta/región:

```bash
export AWS_DEFAULT_REGION=us-west-2
CDK_DOCKER=finch npx cdk bootstrap
```

## Paso 5 — Reemplazar `deploy.sh`

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

## Paso 6 — Completar los TODOs del código

### 6a — Tenant Provisioning Service

En `cdk/lib/tenant-template/tenant-provisioning/tenant_provisioning_service.py`, debajo del comentario `# TODO: Lab1 - Add provision tenant resources`, ya deben estar estas 3 líneas:

```python
__create_opensearch_serverless_tenant_index(tenant_id, kb_collection_endpoint_domain)
__create_s3_tenant_prefix(tenant_id, rule_name)
__create_tenant_knowledge_base(tenant_id, kb_collection_name, rule_name)
```

Si no están, agregarlas manualmente con la indentación correcta (8 espacios).

### 6b — Provision Tenant Script

En `scripts/provision-tenant.sh`, debajo del comentario `# TODO: Lab1 - Add tenant provisioning service`, ya debe estar esta línea:

```bash
tenant_provision_output=$(python3 lib/tenant-template/tenant-provisioning/tenant_provisioning_service.py --tenantid "$CDK_PARAM_TENANT_ID" 2>&1 > /dev/null && exit_code=$?) || exit_code=$?
check_error "$provision_name" $exit_code "$tenant_provision_output"
```

Si no está, agregarla manualmente.

## Paso 6c — Fix ragService (imports + requirements)

El código original de `rag_service.py` importa desde `langchain.chains` y `langchain_community.retrievers`. Sin un `requirements.txt`, el Lambda no encuentra los módulos. Si se agregan las dependencias al `requirements.txt`, se duplican con las del `utilsLayer` (que ya incluye `langchain_aws`, `langchain_core`, `langchain_community`, `langchain`) y el paquete combinado supera el límite de 250 MB.

La solución es dejar el `requirements.txt` vacío y optimizar los imports para usar solo módulos disponibles en el layer.

#### 6c.1 — Dejar `requirements.txt` vacío

Crear `cdk/lib/tenant-template/services/ragService/requirements.txt`:

```text
# Dependencies provided by utilsLayer — do not duplicate here
```

#### 6c.2 — Optimizar imports en `rag_service.py`

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

Usar `RunnablePassthrough` con una cadena LCEL en lugar de `RetrievalQA`. No se necesitan `commandHooks` ni `bundling` especial en `services.ts` — el bundle solo contiene los `.py` del Lambda, sin dependencias pip propias.

## Paso 7 — Desplegar

```bash
cd "/Users/lancdieg/Documents/SA work/lancdieg-notes/Clients/2026/Viajes/2026-03-02-viaje-medellin/Q10/aws-saas-genai-rag-workshop/scripts"
export AWS_DEFAULT_REGION=us-west-2
CDK_DOCKER=finch ./deploy.sh
```

El despliegue toma aproximadamente 15-20 minutos. El script no pide confirmación (`--require-approval never`).

## Troubleshooting

### Error: SSM parameter /cdk-bootstrap/hnb659fds/version not found

CDK no está bootstrapped en la región. Ejecutar:

```bash
export AWS_DEFAULT_REGION=us-west-2
CDK_DOCKER=finch npx cdk bootstrap
```

### Error: No export named SbtEventBus found

El ControlPlaneStack no se desplegó antes del Application Plane. El `deploy.sh` del Paso 5 ya maneja esto automáticamente.

### Docker Desktop no arranca (daemon socket not found)

Si Docker Desktop se instaló pero `docker info` muestra `failed to connect to the docker API`:

1. Abrir Docker Desktop manualmente desde `/Applications/Docker.app`
1. Esperar a que el ícono de la ballena indique que está corriendo
1. Si persiste, usar Finch como alternativa (Paso 1)

### Conflictos de binarios al instalar Docker Desktop

Si `brew install --cask docker` falla con conflictos de `hub-tool`, `kubectl.docker`, o `docker-compose`:

```bash
sudo rm -f /usr/local/bin/hub-tool /usr/local/bin/kubectl.docker /usr/local/cli-plugins/docker-compose
brew install --cask docker --force
```

### Error: No module named 'langchain.chains' / paquete excede 250 MB (ragService)

Al ejecutar `execute-query`, el API Gateway devuelve `Internal server error`. En los logs del Lambda `ragService`:

```text
Runtime.ImportModuleError: Unable to import module 'rag_service': No module named 'langchain.chains'
```

El `utilsLayer` ya incluye `langchain_aws`, `langchain_core`, `langchain_community` y `langchain`. Si el ragService también instala estas dependencias vía su propio `requirements.txt`, el paquete combinado (código + layers) supera el límite de 250 MB.

Solución: dejar `requirements.txt` vacío (las deps vienen del layer) y optimizar imports en `rag_service.py` para usar `langchain_aws` y `langchain_core` (ver Paso 6c). No se necesitan `commandHooks` ni `bundling` especial. Redesplegar.

### Finch: variable CDK_DOCKER

Si se usa Finch, siempre incluir `CDK_DOCKER=finch` antes de cualquier comando CDK. Sin esta variable, CDK intenta usar Docker y falla.

### Error: Model version has reached end of life (amazon.titan-text-lite-v1)

Al ejecutar `execute-query`, el ragService devuelve:

```text
ResourceNotFoundException: This model version has reached the end of its life.
```

El modelo `amazon.titan-text-lite-v1` fue deprecado por AWS. Se reemplazó por Claude Sonnet 4.6 (ver Paso 8).

### KeyError en TenantCostCalculatorService (invoke_model_tenant_cost)

Al invocar el Lambda `TenantCostCalculatorService`, falla con:

```text
KeyError: 'USW2-TitanEmbeddingsG1-Text-input-tokens'
```

El código original accede a los diccionarios `total_service_cost` y `tenant_attribution_percentage_json` con `dict[key]`, que lanza `KeyError` si la clave no existe. Se corrigió usando `.get(key, 0)` para devolver 0 cuando la clave no está presente.

### Labels de CUR no coinciden con datos reales (Lab 4)

El sample CUR del workshop usa modelos Titan G1 (no G2). Los `line_item_usage_type` reales son:

- `USW2-TitanEmbeddingsG1-Text-input-tokens`
- `USW2-TitanTextG1-Lite-input-tokens`
- `USW2-TitanTextG1-Lite-output-tokens`

Si el código tiene labels de G2 o Sonnet, los costos aparecerán en cero. Se alinearon las constantes en `invoke_model_tenant_cost.py` con los valores reales del CUR. Verificar con:

```bash
aws athena start-query-execution \
    --query-string "SELECT DISTINCT line_item_usage_type FROM costusagereport WHERE line_item_product_code = 'AmazonBedrock'" \
    --query-execution-context Database=costexplorerdb \
    --result-configuration OutputLocation=s3://saas-genai-workshop-boots-saasgenaicurworkshopbuck-rwslf0gmv3ku/athena-results/ \
    --region us-west-2
```

### Incompatibilidad de dimensión de vectores después de cambiar modelo de embeddings

Si se provisionaron tenants con Amazon Titan Text Embeddings V1 (dimensión 1536) y luego se cambió a V2 (dimensión 1024), los índices de OpenSearch Serverless existentes son incompatibles. Eliminar los tenants y re-provisionarlos.

## Paso 8 — Cambio de modelos (Claude Sonnet 4.6 + Titan Embed V2)

El workshop original usa modelos deprecados o básicos. Se reemplazaron por:

- Generación de texto: `us.anthropic.claude-sonnet-4-6` (inference profile cross-region)
- Embeddings: `amazon.titan-embed-text-v2:0` (dimensión 1024)

### 8a — Habilitar modelo en Amazon Bedrock

En la consola de Amazon Bedrock → Model access (`us-west-2`), verificar que `anthropic.claude-sonnet-4-6` y `amazon.titan-embed-text-v2` estén habilitados.

### 8b — Archivos ya modificados

Los siguientes cambios ya están aplicados en el repositorio clonado:

1. `rag_service.py`: `MODEL_ID = "us.anthropic.claude-sonnet-4-6"`
1. `services.ts`: ARN IAM cambiado a `inference-profile/us.anthropic.claude-sonnet-4-6`
1. `tenant_provisioning_service.py`: embedding model → `amazon.titan-embed-text-v2:0`, dimensión → 1024
1. `lab4_calculate_kb_input_tokens_attribution.py`: queries de CloudWatch actualizadas
1. `invoke_model_tenant_cost.py`: labels de CUR alineados con datos reales del sample CUR (Titan G1, no G2)
1. `saas-genai-workshop.ts`: región explícita `us-west-2` en los tres stacks
1. `deploy.sh`: variables de entorno `AWS_DEFAULT_REGION` y `CDK_DEFAULT_REGION` fijadas a `us-west-2`

### 8c — Redesplegar y re-provisionar

```bash
cd "/Users/lancdieg/Documents/SA work/lancdieg-notes/Clients/2026/Viajes/2026-03-02-viaje-medellin/Q10/aws-saas-genai-rag-workshop/scripts"
export AWS_DEFAULT_REGION=us-west-2
CDK_DOCKER=finch ./deploy.sh
```

Si ya existían tenants provisionados con el modelo anterior, eliminarlos y re-provisionarlos después del redespliegue.

---

_Autor: Diego Riveros (lancdieg)_  
_Última actualización: 2026-03-02_
