#!/usr/bin/env node

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const defaultWorkflow = new URL('../examples/n8n-brainiall-pdf-to-markdown.json', import.meta.url);
const workflowPath = process.argv[2] ?? fileURLToPath(defaultWorkflow);
const source = readFileSync(workflowPath, 'utf8');
const workflow = JSON.parse(source);

assert.equal(typeof workflow.name, 'string', 'workflow.name must be a string');
assert.ok(Array.isArray(workflow.nodes), 'workflow.nodes must be an array');
assert.equal(workflow.nodes.length, 3, 'expected the trigger, request, and setup note');

const nodeNames = workflow.nodes.map((node) => node.name);
const nodeIds = workflow.nodes.map((node) => node.id);
assert.equal(new Set(nodeNames).size, nodeNames.length, 'node names must be unique');
assert.equal(new Set(nodeIds).size, nodeIds.length, 'node ids must be unique');
assert.ok(workflow.nodes.every((node) => !Object.hasOwn(node, 'credentials')), 'credential IDs must not be embedded');

const form = workflow.nodes.find((node) => node.type === 'n8n-nodes-base.formTrigger');
assert.ok(form, 'Form Trigger node is required');
assert.equal(form.typeVersion, 2.4, 'Form Trigger must use the stable fieldName schema');
assert.equal(form.parameters.authentication, 'basicAuth', 'upload form must require Basic Auth');
const pdfField = form.parameters.formFields?.values?.find((field) => field.fieldName === 'pdf');
assert.ok(pdfField, 'a stable pdf form field is required');
assert.equal(pdfField.fieldType, 'file');
assert.equal(pdfField.multipleFiles, false);
assert.equal(pdfField.requiredField, true);
assert.match(pdfField.acceptFileTypes, /\.pdf/i);

const request = workflow.nodes.find((node) => node.type === 'n8n-nodes-base.httpRequest');
assert.ok(request, 'HTTP Request node is required');
assert.equal(request.typeVersion, 4.4);
assert.equal(request.parameters.method, 'POST');
assert.equal(request.parameters.url, 'https://api.brainiall.com/v1/document/pdf-to-markdown/file');
assert.equal(request.parameters.authentication, 'genericCredentialType');
assert.equal(request.parameters.genericAuthType, 'httpHeaderAuth');
assert.equal(request.parameters.sendBody, true);
assert.equal(request.parameters.contentType, 'multipart-form-data');

const body = request.parameters.bodyParameters?.parameters;
assert.ok(Array.isArray(body), 'multipart body parameters are required');
assert.ok(
  body.some(
    (parameter) =>
      parameter.parameterType === 'formBinaryData' &&
      parameter.name === 'pdf' &&
      parameter.inputDataFieldName === 'pdf',
  ),
  'the uploaded PDF must be forwarded as multipart field pdf',
);
assert.ok(
  body.some((parameter) => parameter.name === 'output_format' && parameter.value === 'markdown'),
  'output_format=markdown is required',
);
assert.equal(request.parameters.options?.response?.response?.responseFormat, 'file');
assert.equal(request.parameters.options?.response?.response?.outputPropertyName, 'markdown');
assert.equal(request.parameters.options?.timeout, 600000);

const nextNode = workflow.connections?.[form.name]?.main?.[0]?.[0];
assert.equal(nextNode?.node, request.name, 'Form Trigger must connect to the HTTP Request');
assert.equal(nextNode?.type, 'main');
assert.equal(nextNode?.index, 0);
assert.equal(workflow.meta?.templateCredsSetupCompleted, false);

assert.doesNotMatch(source, /\b(?:sk|rk|tmrr)_[A-Za-z0-9_-]{12,}\b/, 'possible secret found');
assert.doesNotMatch(
  source,
  /Bearer\s+(?!YOUR_BRAINIALL_API_KEY(?:`|\\|\s|$))[A-Za-z0-9._~-]{12,}/,
  'possible bearer secret found',
);

console.log('PASS: n8n workflow JSON and safety invariants are valid.');
