# Pi Extension Specification: Cross-Model Context Router

## Overview
This specification outlines a custom Pi Extension designed to drastically reduce OpenRouter token costs during long debugging sessions. It implements a two-tier architecture: utilizing a cost-effective model (e.g., DeepSeek V4.1 Flash) for heavy context ingestion and bug assessment, followed by a programmatic conext router to a high-tier model (e.g., ChatGPT Sol) for execution, using a strictly pruned context window.

## Intended Workflow
1. **The Assessment Phase:** The user starts a standard session using a cheaper model. The user instructs the model to investigate a bug, explore the workspace, and gather context, but explicitly instructs it *not* to write the fix.
2. **The Trigger:** Once the cheap model has assessed the situation, the user invokes the extension via a custom registered command (e.g., `/route-context`).
3. **The Extraction (Compression):** The extension automatically prompts the active (cheap) model to generate a strict, highly compressed "dossier." This dossier must contain only the bug summary, root cause, and the exact code snippets/file paths required to implement the fix.
4. **The Context Swap:** The extension manipulates the Pi session state. It creates a new node in the session tree (preserving the old history if needed) and sets the active context for this new node to *only* contain the compressed dossier.
5. **The Model Switch:** The extension utilizes Pi's terminal UI components (e.g., `ctx.ui.select`) to prompt the user to select the high-tier model from their OpenRouter list.
6. **Execution:** The extension programmatically swaps the session's active model to the selected high-tier model. The new model receives only the compressed dossier, minimizing input token costs before writing the final code fix.

## Technical Requirements (TypeScript)
- **Command Registration:** Use Pi's Extension API to register the `/route-context` command.
- **LLM Interfacing:** Programmatically trigger the active model to run the extraction prompt before altering the context.
- **Session State Manipulation:** Safely prune the conversation history by injecting the summarized dossier into a fresh session node.
- **UI Integration:** Implement the model selection prompt using the native Pi UI API.
- **Model Swapping:** Programmatically update the session's active model ID based on the user's selection.

## Instructions for the Pi Agent
Please generate the complete TypeScript code for this extension, including the `index.ts` and `package.json` setup required to run within the Pi architecture. Ensure proper error handling during the API calls and state manipulation phases.
