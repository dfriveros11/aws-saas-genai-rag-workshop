// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { BootstrapTemplateStack } from "../lib/tenant-template/bootstrap-template-stack";
import { ControlPlaneStack } from "../lib/control-plane-stack";
import { CoreUitlsTemplateStack } from "../lib/core-utils-template-stack";

const app = new cdk.App();

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT || process.env.CDK_DEPLOY_ACCOUNT,
  region: process.env.CDK_DEFAULT_REGION || "us-west-2",
};

const controlPlaneStack = new ControlPlaneStack(app, "ControlPlaneStack", {
  env,
  systemAdminRoleName: process.env.CDK_PARAM_SYSTEM_ADMIN_ROLE_NAME,
  systemAdminEmail: process.env.CDK_PARAM_SYSTEM_ADMIN_EMAIL,
});

const CoreUtilsTemplateStack = new CoreUitlsTemplateStack(
  app,
  "saas-genai-workshop-core-utils-stack",
  {
    env,
    controlPlane: controlPlaneStack.controlPlane,
  }
);

const bootstrapTemplateStack = new BootstrapTemplateStack(
  app,
  "saas-genai-workshop-bootstrap-template",
  {
    env,
    coreUtilsStack: CoreUtilsTemplateStack,
    controlPlaneApiGwUrl:
      controlPlaneStack.controlPlane.controlPlaneAPIGatewayUrl,
  }
);
