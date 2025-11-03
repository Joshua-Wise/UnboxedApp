# Unboxed

A native macOS application for converting MBOX email archives to PDF documents. Read more about the application at my [Dev Blog]([https://pages.github.com/](https://jwise.dev/unboxing-vaults-mail/)).

## Features

### Core Functionality
- **MBOX to PDF Conversion** - Convert `.mbox` and `.mbx` files to PDF
- **Dual Output Modes**
  - Single combined PDF with all emails
  - Separate PDFs for each email (packaged in ZIP)
- **Large File Support** - Streaming parser handles multi-GB MBOX files efficiently

### Email Preview & Selection
- **Interactive Email Browser** - Preview emails before conversion
- **Search & Filter** - Find emails by subject, sender, recipient, or body text
- **Flexible Sorting** - Sort by date (newest/oldest), subject, or sender
- **Selective Conversion** - Choose exactly which emails to convert
- **Toggle on/off** - Skip preview for faster batch conversions

### Performance
- **Multi-threaded PDF Generation** - 2-8x faster than sequential processing
- **Configurable Concurrency** - Choose from 1 to 16 concurrent threads
- **Smart Memory Management** - Adjustable email body size limits to prevent crashes
- **Progress Tracking** - Real-time progress updates during conversion

### Customization
- **PDF Naming** - Customize filename components (subject, date, sender)
- **Component Ordering** - Reorder filename parts with drag controls
- **Live Preview** - See filename format before conversion

### Workflow Features
- **Recent Files** - Quick access to recently opened MBOX files
- **Conversion History** - Track last 100 conversions with detailed metrics
- **Drag & Drop** - Drop files onto app window or Dock icon
- **Open Output Folder** - Quick access to converted files

### Reliability
- **Error Recovery** - Continues processing if individual emails fail
- **Encoding Support** - Handles UTF-8, ISO-Latin-1, and encoded headers
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
git clone https://github.com/yourusername/UnboxedApp.git
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
4. **Click "Convert Selected"** and choose output location
5. **Done!** - Open the folder containing your PDFs

### Advanced Settings

**Settings → General → Performance**
- **Concurrent PDF Generation**: Adjust parallel processing (1-16 threads)
  - Sequential (1): Slow but minimal memory
  - Medium (4): Recommended for most users
  - Maximum (16): Fastest on powerful machines

- **Maximum Email Body Size**: Limit email content size (1-60 MB)
  - Prevents memory issues with very large emails
  - Truncates oversized content with clear indicators

**Settings → General → PDF Naming**
- Toggle filename components (Subject, Date, Sender)
- Reorder components using up/down arrows
- Preview the resulting filename format
