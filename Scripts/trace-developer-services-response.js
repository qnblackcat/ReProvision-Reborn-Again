/*
 * Payload-blind Developer Services response trace for ReProvision.
 *
 * This intentionally records only the action name, HTTP status, MIME type,
 * byte count, broad payload category, and NSError domain/code. It never logs
 * request bodies, response bodies, Apple IDs, credentials, headers, or tokens.
 */

'use strict';

if (!ObjC.available) {
    throw new Error('Objective-C runtime is unavailable');
}

const retainedBlocks = [];
const hookedImplementations = new Set();
const targetHost = 'developerservices2.apple.com';
const selector = '- dataTaskWithRequest:completionHandler:';

function objectOrNull(pointer) {
    if (pointer === null || pointer.isNull()) {
        return null;
    }
    return new ObjC.Object(pointer);
}

function textOrNull(value) {
    if (value === null) {
        return null;
    }
    try {
        return value.toString();
    } catch (_) {
        return null;
    }
}

function classifyData(data) {
    if (data === null || Number(data.length()) === 0) {
        return 'empty';
    }

    const count = Math.min(Number(data.length()), 64);
    let bytes;
    try {
        bytes = new Uint8Array(data.bytes().readByteArray(count));
    } catch (_) {
        return 'unreadable';
    }

    let prefix = '';
    for (let index = 0; index < bytes.length; index += 1) {
        const byte = bytes[index];
        prefix += byte >= 32 && byte <= 126 ? String.fromCharCode(byte) : ' ';
    }
    prefix = prefix.trimStart().toLowerCase();

    if (prefix.startsWith('bplist') || prefix.startsWith('<?xml') || prefix.startsWith('<plist')) {
        return 'plist';
    }
    if (prefix.startsWith('<!doctype html') || prefix.startsWith('<html')) {
        return 'html';
    }
    if (prefix.startsWith('{') || prefix.startsWith('[')) {
        return 'json';
    }
    if (bytes[0] === 0x1f && bytes[1] === 0x8b) {
        return 'gzip';
    }
    return 'other';
}

function actionName(url) {
    const withoutQuery = url.split('?')[0];
    const components = withoutQuery.split('/');
    return components[components.length - 1] || 'unknown';
}

function traceResponse(action, dataPointer, responsePointer, errorPointer) {
    const data = objectOrNull(dataPointer);
    const response = objectOrNull(responsePointer);
    const error = objectOrNull(errorPointer);

    let status = null;
    let mimeType = null;
    if (response !== null) {
        try {
            if (response.respondsToSelector_('statusCode')) {
                status = Number(response.statusCode());
            }
        } catch (_) {}
        try {
            mimeType = textOrNull(response.MIMEType());
        } catch (_) {}
    }

    let errorDomain = null;
    let errorCode = null;
    if (error !== null) {
        try { errorDomain = textOrNull(error.domain()); } catch (_) {}
        try { errorCode = Number(error.code()); } catch (_) {}
    }

    console.log(JSON.stringify({
        event: 'developer-services.response',
        action: action,
        status: status,
        mime_type: mimeType,
        bytes: data === null ? 0 : Number(data.length()),
        payload_kind: classifyData(data),
        error_domain: errorDomain,
        error_code: errorCode
    }));
}

for (const className of Object.keys(ObjC.classes)) {
    const candidate = ObjC.classes[className];
    let method;
    try {
        method = candidate[selector];
    } catch (_) {
        continue;
    }
    if (method === undefined || method === null) {
        continue;
    }

    const implementationKey = method.implementation.toString();
    if (hookedImplementations.has(implementationKey)) {
        continue;
    }
    hookedImplementations.add(implementationKey);

    Interceptor.attach(method.implementation, {
        onEnter(args) {
            let request;
            let url;
            try {
                request = new ObjC.Object(args[2]);
                url = request.URL().absoluteString().toString();
            } catch (_) {
                return;
            }
            if (!url.includes(targetHost) || args[3].isNull()) {
                return;
            }

            const action = actionName(url);
            const original = new ObjC.Block(args[3]);
            const wrapped = new ObjC.Block({
                retType: 'void',
                argTypes: ['object', 'object', 'object'],
                implementation(data, response, error) {
                    traceResponse(action, data, response, error);
                    original.implementation(data, response, error);
                }
            });
            retainedBlocks.push(original, wrapped);
            args[3] = wrapped.handle;
        }
    });
}

console.log(JSON.stringify({
    event: 'developer-services.trace-ready',
    hook_count: hookedImplementations.size
}));
