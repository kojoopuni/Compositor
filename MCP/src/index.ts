#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createServer } from "./server.js";

// Anything written to stdout would corrupt the protocol, so diagnostics go to stderr.
await createServer().connect(new StdioServerTransport());
console.error("compositor-mcp-server is running on stdio");
