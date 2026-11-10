# Unboxed

A native macOS application for converting MBOX email archives to PDF documents. Read more about the application on [my dev blog](https://jwise.dev/unboxing-vaults-mail).


![Unboxed Screenshot](https://jwise.dev/content/images/2025/11/Screenshot-2025-11-03-at-11.57.45-AM.png "Unboxed Screenshot")

## Features

### Core Functionality
- **MBOX to PDF Conversion** - Convert `.mbox` and `.mbx` files to PDF
- **Dual Output Modes**
  - Single combined PDF with all emails
  - Separate PDFs for each email (packaged in ZIP)
- **Large File Support** - Memory-mapped reader handles multi-GB MBOX files efficiently

### Email Preview & Selection
- **Interactive Email Browser** - Preview emails before conversion
- **Search & Filter** - Find emails by subject, sender, recipient, or body text
- **Flexible Sorting** - Sort by date (newest/oldest), subject, or sender
- **Selective Conversion** - Choose exactly which emails to convert
- **Toggle on/off** - Skip preview for faster batch conversions

### Performance
- **Memory-Mapped Indexing** - Files are indexed in place rather than loaded; memory use scales with the number of emails, not the file size
- **Parallel PDF Generation** - Emails are decoded, laid out and written across all CPU cores, off the main thread
- **Responsive UI** - Throttled progress updates and a Cancel button that works at every stage
- **No Network Access** - HTML is rendered by a built-in converter; remote images and trackers are never fetched

### Attachments
- **Merge into PDF** - Text and image attachments can be embedded in the PDF
- **Bundle the Rest** - Other attachments are saved alongside the output

### Customization
- **PDF Naming** - Customize filename components (subject, date, sender)
- **Component Ordering** - Reorder filename parts with up/down controls
- **Live Preview** - See filename format before conversion

### Workflow Features
- **Recent Files** - Quick access to recently opened MBOX files
- **Conversion History** - Track last 100 conversions with detailed metrics
- **Drag & Drop** - Drop files onto the app window
- **Compact File List** - Add or remove files before processing; the action bar stays visible at any window size
- **Open Output Folder** - Quick access to converted files

### Reliability
- **Error Recovery** - Continues processing if individual emails fail
- **Encoding Support** - Decodes any declared character set, quoted-printable/base64 bodies, and RFC 2047/2231 encoded headers and filenames
- **Nested MIME Support** - Finds the message body inside nested multipart structures, with inline (cid) images
- **Malformed Email Handling** - Skips corrupted emails with detailed reporting
- **Date Format Detection** - Automatically parses multiple date formats

## Installation

### Download
1. Download the latest release from [Releases](../../releases)
2. Drag `Unboxed.app` to your Applications folder
3. Right-click and select "Open" on first launch (macOS security)

### Build from Source
```bash
# Clone the repository
git clone https://github.com/Joshua-Wise/UnboxedApp.git
cd UnboxedApp

# Open in Xcode
open Unboxed.xcodeproj

# Build and run (⌘R)
```

## Usage

### Basic Conversion

1. **Launch Unboxed** and drag MBOX files into the window (or press `⌘O`)
2. **Click "Process Files"** to parse emails
3. **Review & Select** emails in the preview window (or disable preview in Settings)
4. **Click "Convert Selected"** and choose the output location
5. **Done!** - Open the folder containing your PDFs

### Settings

**Conversion Options**
- **Generate PDF per Email**: one PDF per email, packaged in a ZIP, instead of a single combined PDF
- **Show Email Preview & Selection**: review, search and select emails before converting
- **Prefer Formatted (HTML) Message Body**: when an email has both a formatted and a plain-text version, use the formatted one (on by default)

**Attachment Handling**
- **Merge Text/Image Attachments into PDF**: embeds text and image attachments after the message body
- **Bundle Other Attachments**: saves every attachment that is not merged into the PDF, in an `attachments` folder inside the ZIP, or in a separate `.attachments.zip` next to a single PDF

**PDF Naming (separate PDFs only)**
- Toggle filename components (Subject, Date, Sender)
- Reorder components using up/down arrows
- Preview the resulting filename format

## Notes on Rendering

- HTML emails are rendered by a built-in converter rather than a browser engine. Text styling, links, lists, quotes, bordered tables and inline images are supported; layout tables are flattened to text and CSS backgrounds are ignored.
- Remote images are never downloaded; their alt text is shown instead.
- Links in the generated PDFs are clickable.

## Requirements

- macOS 13 or later
- Xcode 26 or later to build from source
