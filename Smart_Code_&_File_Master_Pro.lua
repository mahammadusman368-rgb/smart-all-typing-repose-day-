-- Extension Name: Smart Code & File Master Pro
-- Creator: Mohammad Usman
-- Version: 7.0 (Final Verified Edition)
-- Compatibility: Android 8.0 to Android 16+ (Jieshuo Screen Reader)

require "import"
import "android.widget.*"
import "android.view.*"
import "android.view.accessibility.AccessibilityEvent"
import "android.content.Context"
import "android.content.Intent"
import "android.content.ClipData"
import "android.net.Uri"
import "android.media.ToneGenerator"
import "android.media.AudioManager"
import "android.os.Handler"
import "android.os.Looper"
import "java.lang.Runnable"
import "java.io.File"
import "java.io.FileOutputStream"
import "java.io.FileInputStream"
import "java.io.BufferedOutputStream"
import "java.io.BufferedInputStream"
import "java.util.zip.ZipOutputStream"
import "java.util.zip.ZipInputStream"
import "java.util.zip.ZipEntry"
import "java.lang.String"

local dlg = LuaDialog()

-- Main Phone Storage & Extension Folder Setup
local rootStorage = "/sdcard/"
local pluginFolder = "/sdcard/Smart_Code_And_File_Master_Pro/"
local configFilePath = pluginFolder .. ".sound_config.txt"

local dir = File(pluginFolder)
if not dir.exists() then
  dir.mkdirs()
end

local whatsappNumber = "+923261421100"

-- Persistent Sound Tone State (Default ON, remembers user choice forever)
local soundEnabled = true

local function loadSettings()
  local f = io.open(configFilePath, "r")
  if f then
    local data = f:read("*a")
    f:close()
    if data and data:find("sound=false") then
      soundEnabled = false
    else
      soundEnabled = true
    end
  end
end

local function saveSettings()
  local f = io.open(configFilePath, "w")
  if f then
    f:write("sound=" .. tostring(soundEnabled) .. "\n")
    f:close()
  end
end

loadSettings()

-- Function: Play Completion Tone (Only if Sound Tone is ON)
local function playCompletionTone(isSuccess)
  if not soundEnabled then return end
  pcall(function()
    local toneType = isSuccess and ToneGenerator.TONE_PROP_ACK or ToneGenerator.TONE_PROP_NACK
    local toneGen = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 85)
    toneGen.startTone(toneType, 160)
  end)
end

-- Function: English Voice Guidance + Toast + Completion Tone
local function notifyUser(msg, isSuccess)
  service.speak(msg)
  Toast.makeText(service, msg, Toast.LENGTH_SHORT).show()
  if isSuccess ~= nil then
    playCompletionTone(isSuccess)
  end
end

-- Helper Function: Safely convert Java File Array to Lua Table
local function javaArrayToTable(javaArr)
  local list = {}
  if not javaArr then return list end
  if luajava and luajava.astable then
    local ok, res = pcall(luajava.astable, javaArr)
    if ok and type(res) == "table" then
      return res
    end
  end
  local okLen, len = pcall(function() return #javaArr end)
  if okLen and len and len > 0 then
    for i = 0, len - 1 do
      table.insert(list, javaArr[i])
    end
  end
  return list
end

-- Helper Function: Safe 4KB Byte Buffer for Zip/Unzip
local function createByteBuffer(size)
  return String(string.rep("\0", size or 4096)).getBytes()
end

-- Fast File Reader & Writer
local function readFileFast(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local content = f:read("*a")
  f:close()
  return content
end

local function writeFileFast(path, content)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(content)
  f:close()
  return true
end

-- Function: Count Characters, Words, and Lines accurately
local function getTextStats(text)
  if not text or text == "" then
    return 0, 0, 0
  end
  local charCount = #text
  local wordCount = 0
  for _ in text:gmatch("%S+") do
    wordCount = wordCount + 1
  end
  local lineCount = 1
  for _ in text:gmatch("\n") do
    lineCount = lineCount + 1
  end
  return charCount, wordCount, lineCount
end

-- Function: Copy Text to Clipboard
local function copyToClipboard(text, customMsg)
  if not text or text == "" then
    notifyUser("There is no text to copy.", false)
    return
  end
  local clipboard = service.getSystemService(Context.CLIPBOARD_SERVICE)
  local clip = ClipData.newPlainText("SmartCodeMaster", text)
  clipboard.setPrimaryClip(clip)
  notifyUser(customMsg or "Code copied to clipboard successfully.", true)
end

-- Function: Clean File Name (Automatically fixes spaces & invalid symbols)
local function sanitizeFileName(rawName)
  local cleaned = rawName:gsub("^%s+", ""):gsub("%s+$", "")
  cleaned = cleaned:gsub("[\\/:*?\"<>|]", "_")
  cleaned = cleaned:gsub("%s+", "_")
  return cleaned
end

-- File Categories List (Default: .lua)
local fileCategories = {
  ".lua",
  ".txt",
  ".json",
  ".xml",
  ".html",
  ".sh",
  ".prop",
  ".js",
  ".css",
  ".md"
}
local selectedExtension = ".lua"

-- Table to hold Main UI Views
local views = {}

-- Function: Live Update Counter Display (Placed right after Code EditBox)
local lastTrackedText = ""
local lastTrackedExt = ".lua"

local function updateCounterDisplay(forceUpdate)
  if views.edtTextContent and views.txtCounter then
    local currentText = tostring(views.edtTextContent.Text or "")
    if forceUpdate or currentText ~= lastTrackedText or selectedExtension ~= lastTrackedExt then
      lastTrackedText = currentText
      lastTrackedExt = selectedExtension
      local chars, words, lines = getTextStats(currentText)
      views.txtCounter.Text = string.format("Characters: %d | Words: %d | Lines: %d | Format: %s", chars, words, lines, selectedExtension)
    end
  end
end

-- Reliable Live Counter Loop (Runs smoothly while dialog is open)
local counterHandler = Handler(Looper.getMainLooper())
local isDialogActive = true
local counterRunnable

counterRunnable = Runnable{
  run = function()
    if isDialogActive then
      pcall(updateCounterDisplay, false)
      counterHandler.postDelayed(counterRunnable, 350)
    end
  end
}
counterHandler.postDelayed(counterRunnable, 350)

-- =========================================================================
-- 1. SAFE CODE CLEANER (Removes Junk Spaces/Empty Lines Without Breaking Code)
-- =========================================================================
local function cleanCodeSafely(rawCode)
  if not rawCode or rawCode == "" then
    return ""
  end
  local code = rawCode:gsub("\r\n", "\n"):gsub("\r", "\n")
  -- Remove invisible zero-width junk characters (UTF-8 BOM / zero-width space)
  code = code:gsub("\239\187\191", "")
  code = code:gsub("\226\128\139", "")
  
  local cleanedLines = {}
  local previousWasBlank = false
  
  for line in (code .. "\n"):gmatch("([^\n]*)\n") do
    local trimmedRight = line:gsub("[ \t]+$", "")
    if trimmedRight == "" then
      if not previousWasBlank then
        table.insert(cleanedLines, "")
        previousWasBlank = true
      end
    else
      table.insert(cleanedLines, trimmedRight)
      previousWasBlank = false
    end
  end
  
  local result = table.concat(cleanedLines, "\n")
  result = result:gsub("^\n+", ""):gsub("\n+$", "")
  return result
end

-- =========================================================================
-- 2. ZIP COMPRESS & UNZIP EXTRACT ENGINE
-- =========================================================================
local function addFileToZip(zipOut, fileObj, parentPath)
  local entryName = parentPath .. fileObj.getName()
  if fileObj.isDirectory() then
    entryName = entryName .. "/"
    zipOut.putNextEntry(ZipEntry(entryName))
    zipOut.closeEntry()
    local children = fileObj.listFiles()
    if children then
      local childTable = javaArrayToTable(children)
      for _, child in ipairs(childTable) do
        addFileToZip(zipOut, child, entryName)
      end
    end
  else
    local fi = FileInputStream(fileObj)
    local origin = BufferedInputStream(fi, 4096)
    local entry = ZipEntry(entryName)
    zipOut.putNextEntry(entry)
    local buffer = createByteBuffer(4096)
    local count = origin.read(buffer, 0, 4096)
    while count ~= -1 do
      zipOut.write(buffer, 0, count)
      count = origin.read(buffer, 0, 4096)
    end
    origin.close()
    fi.close()
    zipOut.closeEntry()
  end
end

local function compressFilesToZip(selectedFilePaths, destinationZipPath)
  local ok, err = pcall(function()
    local destFile = File(destinationZipPath)
    local fos = FileOutputStream(destFile)
    local zipOut = ZipOutputStream(BufferedOutputStream(fos))
    for _, path in ipairs(selectedFilePaths) do
      local f = File(path)
      if f.exists() then
        addFileToZip(zipOut, f, "")
      end
    end
    zipOut.close()
    fos.close()
  end)
  return ok, err
end

local function extractZipArchive(zipFilePath, outputFolderPath)
  local ok, err = pcall(function()
    local outDir = File(outputFolderPath)
    if not outDir.exists() then
      outDir.mkdirs()
    end
    local fis = FileInputStream(File(zipFilePath))
    local zis = ZipInputStream(BufferedInputStream(fis))
    local buffer = createByteBuffer(4096)
    
    local entry = zis.getNextEntry()
    while entry ~= nil do
      local outPath = outputFolderPath .. "/" .. entry.getName()
      local outFile = File(outPath)
      if entry.isDirectory() then
        outFile.mkdirs()
      else
        local parent = outFile.getParentFile()
        if parent and not parent.exists() then
          parent.mkdirs()
        end
        local fos = FileOutputStream(outFile)
        local dest = BufferedOutputStream(fos, 4096)
        local count = zis.read(buffer, 0, 4096)
        while count ~= -1 do
          dest.write(buffer, 0, count)
          count = zis.read(buffer, 0, 4096)
        end
        dest.flush()
        dest.close()
        fos.close()
      end
      zis.closeEntry()
      entry = zis.getNextEntry()
    end
    zis.close()
    fis.close()
  end)
  return ok, err
end

-- =========================================================================
-- 3. PHONE STORAGE BROWSER (2 Bottom Button Rows + Folder Popup + Multi-Check)
-- =========================================================================
local function openFileBrowser(startFolder)
  local currentPath = startFolder or rootStorage
  local browserDlg = LuaDialog()
  browserDlg.setTitle("Browse Phone Storage")
  
  local bViews = {}
  local itemEntries = {}
  local checkedMap = {}
  
  local browserLayout = {
    LinearLayout,
    orientation = "vertical",
    padding = "16dp",
    layout_width = "fill",
    layout_height = "fill",
    {
      TextView,
      id = "txtCurrentPath",
      text = "Folder: " .. currentPath,
      textSize = "13sp",
      layout_marginBottom = "8dp",
    },
    -- Full Height ListView (Takes all available top space regardless of item count)
    {
      ListView,
      id = "browserListView",
      layout_width = "fill",
      layout_height = "300dp",
      layout_weight = 1,
      layout_marginBottom = "10dp",
    },
    -- Bottom Row 1 (4 Buttons: View Text | Compress | Extract | Rename)
    {
      LinearLayout,
      orientation = "horizontal",
      layout_width = "fill",
      layout_marginBottom = "6dp",
      {
        Button,
        id = "btnViewText",
        text = "View Text",
        layout_weight = 1,
        textSize = "13sp",
      },
      {
        Button,
        id = "btnCompress",
        text = "Compress",
        layout_weight = 1,
        textSize = "13sp",
      },
      {
        Button,
        id = "btnExtract",
        text = "Extract",
        layout_weight = 1,
        textSize = "13sp",
      },
      {
        Button,
        id = "btnRename",
        text = "Rename",
        layout_weight = 1,
        textSize = "13sp",
      },
    },
    -- Bottom Row 2 (3 Buttons: Delete | Parent Folder | Go Back)
    {
      LinearLayout,
      orientation = "horizontal",
      layout_width = "fill",
      layout_marginBottom = "18dp",
      {
        Button,
        id = "btnDelete",
        text = "Delete",
        layout_weight = 1,
        textSize = "14sp",
      },
      {
        Button,
        id = "btnParentFolder",
        text = "Parent Folder",
        layout_weight = 1,
        textSize = "14sp",
      },
      {
        Button,
        id = "btnBrowserBack",
        text = "Go Back",
        layout_weight = 1,
        textSize = "14sp",
      },
    },
  }
  
  browserDlg.setView(loadlayout(browserLayout, bViews))
  
  local function updateListAdapter()
    local displayNames = {}
    for i, item in ipairs(itemEntries) do
      local prefix = checkedMap[i] and "[Selected] " or ""
      if item.isDir then
        table.insert(displayNames, prefix .. "[Folder] " .. item.name)
      else
        table.insert(displayNames, prefix .. item.name .. " (" .. item.sizeKb .. " KB)")
      end
    end
    if #displayNames == 0 then
      table.insert(displayNames, "[Empty Folder]")
    end
    local adapter = ArrayAdapter(service, android.R.layout.simple_list_item_1, displayNames)
    bViews.browserListView.Adapter = adapter
  end
  
  local function refreshDirectory(pathToLoad)
    local fDir = File(pathToLoad)
    if not fDir.exists() or not fDir.isDirectory() then
      notifyUser("Cannot open this folder.", false)
      return
    end
    currentPath = fDir.getAbsolutePath()
    if not currentPath:find("/$") then
      currentPath = currentPath .. "/"
    end
    bViews.txtCurrentPath.Text = "Folder: " .. currentPath
    
    itemEntries = {}
    checkedMap = {}
    local rawFiles = fDir.listFiles()
    
    if rawFiles then
      local fileTable = javaArrayToTable(rawFiles)
      table.sort(fileTable, function(a, b)
        if a.isDirectory() and not b.isDirectory() then
          return true
        elseif not a.isDirectory() and b.isDirectory() then
          return false
        else
          return a.getName():lower() < b.getName():lower()
        end
      end)
      
      for _, fileObj in ipairs(fileTable) do
        local name = fileObj.getName()
        if not name:find("^%.") then
          local isDir = fileObj.isDirectory()
          local sizeKb = isDir and 0 or math.ceil(fileObj.length() / 1024)
          table.insert(itemEntries, {
            name = name,
            path = fileObj.getAbsolutePath(),
            isDir = isDir,
            sizeKb = sizeKb
          })
        end
      end
    end
    updateListAdapter()
  end
  
  local function getSelectedItems()
    local list = {}
    for i, item in ipairs(itemEntries) do
      if checkedMap[i] then
        table.insert(list, item)
      end
    end
    return list
  end
  
  -- Item Click Logic:
  -- 1. If Folder clicked -> Show Popup ("View Folder" | "Select")
  -- 2. If File clicked -> Toggle Check/Select directly for single or multiple selection
  bViews.browserListView.onItemClick = function(parent, view, position, id)
    local idx = position + 1
    local item = itemEntries[idx]
    if not item then return end
    
    if item.isDir then
      local folderPop = LuaDialog()
      folderPop.setTitle(item.name)
      local fpViews = {}
      local isCurrentlySelected = checkedMap[idx] and true or false
      
      local popLayout = {
        LinearLayout,
        orientation = "vertical",
        padding = "20dp",
        {
          TextView,
          text = "Choose action for folder: " .. item.name,
          textSize = "15sp",
          layout_marginBottom = "16dp",
        },
        {
          LinearLayout,
          orientation = "horizontal",
          layout_width = "fill",
          {
            Button,
            id = "btnPopViewFolder",
            text = "View Folder",
            layout_weight = 1,
          },
          {
            Button,
            id = "btnPopSelectFolder",
            text = isCurrentlySelected and "Unselect" or "Select",
            layout_weight = 1,
          },
        }
      }
      folderPop.setView(loadlayout(popLayout, fpViews))
      
      fpViews.btnPopViewFolder.onClick = function()
        folderPop.dismiss()
        refreshDirectory(item.path)
        notifyUser("Opened folder " .. item.name, true)
      end
      
      fpViews.btnPopSelectFolder.onClick = function()
        folderPop.dismiss()
        checkedMap[idx] = not isCurrentlySelected
        updateListAdapter()
        if checkedMap[idx] then
          notifyUser("Folder selected: " .. item.name, true)
        else
          notifyUser("Folder unselected: " .. item.name, false)
        end
      end
      
      folderPop.show()
    else
      -- File Clicked: Toggle Check/Select directly
      checkedMap[idx] = not checkedMap[idx]
      updateListAdapter()
      if checkedMap[idx] then
        notifyUser("Selected: " .. item.name, true)
      else
        notifyUser("Unselected: " .. item.name, false)
      end
    end
  end
  
  -- Row 1 Button 1: View Text
  bViews.btnViewText.onClick = function()
    local selected = getSelectedItems()
    if #selected == 0 then
      notifyUser("Please select a file from the list first.", false)
      return
    end
    if #selected > 1 then
      notifyUser("Please select only one file to view.", false)
      return
    end
    local item = selected[1]
    if item.isDir then
      refreshDirectory(item.path)
      notifyUser("Opened folder " .. item.name, true)
      return
    end
    local lowerName = item.name:lower()
    if lowerName:find("%.zip$") or lowerName:find("%.apk$") or lowerName:find("%.rar$") or lowerName:find("%.7z$") then
      notifyUser("This is an archive file. Please use the Extract button.", false)
      return
    end
    local content, err = readFileFast(item.path)
    if not content then
      notifyUser("Failed to read file: " .. tostring(err), false)
      return
    end
    local baseName = item.name:gsub("%.%w+$", "")
    views.edtFileName.Text = baseName
    views.edtTextContent.Text = content
    updateCounterDisplay(true)
    notifyUser("File code loaded into main editor successfully.", true)
    browserDlg.dismiss()
  end
  
  -- Row 1 Button 2: Compress (Zip)
  bViews.btnCompress.onClick = function()
    local selected = getSelectedItems()
    if #selected == 0 then
      notifyUser("Please select at least one file or folder to compress.", false)
      return
    end
    
    local zipDlg = LuaDialog()
    zipDlg.setTitle("Compress to Zip")
    local zViews = {}
    local defaultZipName = selected[1].name:gsub("%.%w+$", "")
    
    local zipLayout = {
      LinearLayout,
      orientation = "vertical",
      padding = "20dp",
      {
        TextView,
        text = "Selected Items: " .. #selected .. "\nEnter Zip File Name:",
        textSize = "15sp",
        layout_marginBottom = "10dp",
      },
      {
        EditText,
        id = "edtZipName",
        text = defaultZipName,
        hint = "Enter Zip Name",
        layout_width = "fill",
        layout_marginBottom = "15dp",
      },
      {
        LinearLayout,
        orientation = "horizontal",
        layout_width = "fill",
        {
          Button,
          id = "btnConfirmZip",
          text = "Create Zip",
          layout_weight = 1,
        },
        {
          Button,
          id = "btnCancelZip",
          text = "Cancel",
          layout_weight = 1,
        },
      }
    }
    zipDlg.setView(loadlayout(zipLayout, zViews))
    
    zViews.btnConfirmZip.onClick = function()
      local zName = sanitizeFileName(tostring(zViews.edtZipName.Text))
      if zName == "" then
        notifyUser("Please enter a valid zip name.", false)
        return
      end
      if not zName:lower():find("%.zip$") then
        zName = zName .. ".zip"
      end
      
      local paths = {}
      for _, it in ipairs(selected) do
        table.insert(paths, it.path)
      end
      
      local outZipPath = currentPath .. zName
      local ok, err = compressFilesToZip(paths, outZipPath)
      zipDlg.dismiss()
      if ok then
        refreshDirectory(currentPath)
        notifyUser("Compressed successfully into " .. zName, true)
      else
        notifyUser("Compression failed: " .. tostring(err), false)
      end
    end
    
    zViews.btnCancelZip.onClick = function()
      zipDlg.dismiss()
    end
    zipDlg.show()
  end
  
  -- Row 1 Button 3: Extract (Unzip)
  bViews.btnExtract.onClick = function()
    local selected = getSelectedItems()
    if #selected == 0 then
      notifyUser("Please select a Zip or APK file to extract.", false)
      return
    end
    if #selected > 1 then
      notifyUser("Please select only one archive file at a time to extract.", false)
      return
    end
    local item = selected[1]
    local lower = item.name:lower()
    if item.isDir then
      notifyUser("Selected item is a folder. Please select a Zip file to extract.", false)
      return
    end
    if lower:find("%.rar$") or lower:find("%.7z$") then
      notifyUser("Only ZIP, APK, and JAR archive formats are supported for extraction.", false)
      return
    end
    if not lower:find("%.zip$") and not lower:find("%.apk$") and not lower:find("%.jar$") then
      notifyUser("Please select a valid Zip or APK file to extract.", false)
      return
    end
    
    local folderName = item.name:gsub("%.%w+$", "") .. "_Extracted"
    local extractTarget = currentPath .. folderName
    local ok, err = extractZipArchive(item.path, extractTarget)
    if ok then
      refreshDirectory(currentPath)
      notifyUser("File extracted successfully into folder " .. folderName, true)
    else
      notifyUser("Extraction failed: " .. tostring(err), false)
    end
  end
  
  -- Row 1 Button 4: Rename File or Folder
  bViews.btnRename.onClick = function()
    local selected = getSelectedItems()
    if #selected == 0 then
      notifyUser("Please select a file or folder to rename.", false)
      return
    end
    if #selected > 1 then
      notifyUser("Please select only one item to rename.", false)
      return
    end
    local item = selected[1]
    
    local renDlg = LuaDialog()
    renDlg.setTitle("Rename")
    local rViews = {}
    
    local renLayout = {
      LinearLayout,
      orientation = "vertical",
      padding = "20dp",
      {
        TextView,
        text = "Current Name: " .. item.name,
        textSize = "15sp",
        layout_marginBottom = "10dp",
      },
      {
        EditText,
        id = "edtNewName",
        text = item.name,
        hint = "Enter New Name",
        layout_width = "fill",
        layout_marginBottom = "15dp",
      },
      {
        LinearLayout,
        orientation = "horizontal",
        layout_width = "fill",
        {
          Button,
          id = "btnConfirmRename",
          text = "Save Name",
          layout_weight = 1,
        },
        {
          Button,
          id = "btnCancelRename",
          text = "Cancel",
          layout_weight = 1,
        },
      }
    }
    renDlg.setView(loadlayout(renLayout, rViews))
    
    rViews.btnConfirmRename.onClick = function()
      local newName = tostring(rViews.edtNewName.Text):gsub("^%s+", ""):gsub("%s+$", "")
      if newName == "" or newName == item.name then
        notifyUser("Please enter a different valid name.", false)
        return
      end
      local oldFile = File(item.path)
      local newFile = File(currentPath .. newName)
      if newFile.exists() then
        notifyUser("An item with this name already exists.", false)
        return
      end
      local renamed = oldFile.renameTo(newFile)
      renDlg.dismiss()
      if renamed then
        refreshDirectory(currentPath)
        notifyUser("Renamed successfully to " .. newName, true)
      else
        notifyUser("Rename failed.", false)
      end
    end
    
    rViews.btnCancelRename.onClick = function()
      renDlg.dismiss()
    end
    renDlg.show()
  end
  
  -- Row 2 Button 1: Delete (with Confirmation)
  bViews.btnDelete.onClick = function()
    local selected = getSelectedItems()
    if #selected == 0 then
      notifyUser("Please select at least one item to delete.", false)
      return
    end
    
    local confirmDlg = LuaDialog()
    confirmDlg.setTitle("Confirm Delete")
    local cViews = {}
    
    local confirmLayout = {
      LinearLayout,
      orientation = "vertical",
      padding = "20dp",
      {
        TextView,
        text = "Are you sure you want to delete " .. #selected .. " selected item(s)?",
        textSize = "16sp",
        layout_marginBottom = "20dp",
      },
      {
        LinearLayout,
        orientation = "horizontal",
        layout_width = "fill",
        {
          Button,
          id = "btnConfirmDel",
          text = "Confirm Delete",
          layout_weight = 1,
        },
        {
          Button,
          id = "btnCancelDel",
          text = "Cancel",
          layout_weight = 1,
        },
      }
    }
    confirmDlg.setView(loadlayout(confirmLayout, cViews))
    
    local function deleteRecursively(fileObj)
      if fileObj.isDirectory() then
        local children = fileObj.listFiles()
        if children then
          local cTable = javaArrayToTable(children)
          for _, child in ipairs(cTable) do
            deleteRecursively(child)
          end
        end
      end
      return fileObj.delete()
    end
    
    cViews.btnConfirmDel.onClick = function()
      local delCount = 0
      for _, it in ipairs(selected) do
        if deleteRecursively(File(it.path)) then
          delCount = delCount + 1
        end
      end
      confirmDlg.dismiss()
      refreshDirectory(currentPath)
      notifyUser("Deleted " .. delCount .. " item(s) successfully.", true)
    end
    
    cViews.btnCancelDel.onClick = function()
      confirmDlg.dismiss()
      notifyUser("Delete cancelled.", false)
    end
    confirmDlg.show()
  end
  
  -- Row 2 Button 2: Parent Folder
  bViews.btnParentFolder.onClick = function()
    local curFile = File(currentPath)
    local parentFile = curFile.getParentFile()
    if parentFile and parentFile.exists() and parentFile.canRead() then
      refreshDirectory(parentFile.getAbsolutePath())
      notifyUser("Moved to parent folder.", true)
    else
      notifyUser("Already at main phone storage.", false)
    end
  end
  
  -- Row 2 Button 3: Go Back
  bViews.btnBrowserBack.onClick = function()
    browserDlg.dismiss()
    notifyUser("Returned to main menu.", true)
  end
  
  refreshDirectory(currentPath)
  browserDlg.show()
end

-- =========================================================================
-- 4. SMART CODE SPLITTER (Line-Safe Equal Division without Breaking Code)
-- =========================================================================
local function splitCodeIntoSafeParts(fullText, numParts)
  local lines = {}
  for line in (fullText .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  
  local totalChars = #fullText
  local targetPerPart = math.ceil(totalChars / numParts)
  local parts = {}
  local currentChunk = {}
  local currentLen = 0
  
  for i, line in ipairs(lines) do
    table.insert(currentChunk, line)
    currentLen = currentLen + #line + 1
    
    if currentLen >= targetPerPart and #parts < (numParts - 1) then
      table.insert(parts, table.concat(currentChunk, "\n"))
      currentChunk = {}
      currentLen = 0
    end
  end
  
  if #currentChunk > 0 then
    table.insert(parts, table.concat(currentChunk, "\n"))
  end
  
  return parts
end

local function openCodeSplitterWindow()
  local fullCode = tostring(views.edtTextContent.Text)
  if fullCode == "" then
    notifyUser("Please paste or load code first before splitting.", false)
    return
  end
  
  local totalChars, totalWords, totalLines = getTextStats(fullCode)
  local defaultParts = math.max(2, math.ceil(totalChars / 35000))
  
  local splitDlg = LuaDialog()
  splitDlg.setTitle("Split Code")
  local sViews = {}
  
  local splitLayout = {
    ScrollView,
    layout_width = "fill",
    layout_height = "fill",
    fillViewport = true,
    {
      LinearLayout,
      orientation = "vertical",
      padding = "20dp",
      {
        TextView,
        text = string.format("Total Characters: %d | Words: %d | Lines: %d", totalChars, totalWords, totalLines),
        textSize = "14sp",
        layout_marginBottom = "12dp",
      },
      {
        LinearLayout,
        orientation = "horizontal",
        layout_width = "fill",
        layout_marginBottom = "12dp",
        {
          EditText,
          id = "edtPartCount",
          text = tostring(defaultParts),
          hint = "Parts Count",
          inputType = "number",
          layout_weight = 1,
        },
        {
          Button,
          id = "btnGenerateParts",
          text = "Split Now",
          layout_weight = 1,
        },
      },
      {
        LinearLayout,
        id = "partsContainer",
        orientation = "vertical",
        layout_width = "fill",
        layout_marginBottom = "15dp",
      },
      {
        Button,
        id = "btnSplitBack",
        text = "Go Back",
        layout_width = "fill",
        layout_marginBottom = "25dp",
        textSize = "16sp",
      },
    }
  }
  
  splitDlg.setView(loadlayout(splitLayout, sViews))
  
  local function renderSplitBoxes(numParts)
    sViews.partsContainer.removeAllViews()
    local partsList = splitCodeIntoSafeParts(fullCode, numParts)
    local charCursor = 1
    
    for idx, partText in ipairs(partsList) do
      local pChars, pWords, pLines = getTextStats(partText)
      local startChar = charCursor
      local endChar = charCursor + pChars - 1
      charCursor = endChar + 2
      
      local itemViews = {}
      local partBoxLayout = {
        LinearLayout,
        orientation = "vertical",
        layout_width = "fill",
        layout_marginBottom = "18dp",
        {
          TextView,
          text = string.format("Part %d of %d | Characters: %d (%d to %d) | Lines: %d", idx, #partsList, pChars, startChar, math.max(startChar, endChar), pLines),
          textSize = "14sp",
          layout_marginBottom = "6dp",
        },
        {
          EditText,
          id = "edtPartBox",
          text = partText,
          hint = "Part " .. idx,
          layout_width = "fill",
          layout_height = "130dp",
          gravity = "top",
          layout_marginBottom = "6dp",
        },
        {
          Button,
          id = "btnCopyPart",
          text = "Copy Part " .. idx,
          layout_width = "fill",
        },
      }
      
      local partView = loadlayout(partBoxLayout, itemViews)
      itemViews.btnCopyPart.onClick = function()
        copyToClipboard(tostring(itemViews.edtPartBox.Text), "Part " .. idx .. " copied to clipboard.")
      end
      sViews.partsContainer.addView(partView)
    end
    notifyUser("Code divided into " .. #partsList .. " equal parts successfully.", true)
  end
  
  sViews.btnGenerateParts.onClick = function()
    local requested = tonumber(tostring(sViews.edtPartCount.Text))
    if not requested or requested < 2 then
      notifyUser("Please enter at least 2 parts.", false)
      return
    end
    if requested > 50 then
      notifyUser("Maximum 50 parts allowed.", false)
      return
    end
    renderSplitBoxes(requested)
  end
  
  sViews.btnSplitBack.onClick = function()
    splitDlg.dismiss()
    notifyUser("Returned to main menu.", true)
  end
  
  renderSplitBoxes(defaultParts)
  splitDlg.show()
end

-- =========================================================================
-- 5. SURGICAL LINE-BY-LINE EDITOR (Select, Replace, Delete, Find Line, Syntax Check)
-- =========================================================================
local function openLineEditorWindow()
  local fullCode = tostring(views.edtTextContent.Text)
  if fullCode == "" then
    notifyUser("Please paste or load code first before editing lines.", false)
    return
  end
  
  local codeLines = {}
  local normalized = fullCode:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (normalized .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(codeLines, line)
  end
  
  local lineDlg = LuaDialog()
  lineDlg.setTitle("Edit Lines")
  local lViews = {}
  
  local lineEditorLayout = {
    ScrollView,
    layout_width = "fill",
    layout_height = "fill",
    fillViewport = true,
    {
      LinearLayout,
      orientation = "vertical",
      padding = "20dp",
      {
        TextView,
        id = "txtLineStatus",
        text = "Total Lines: " .. #codeLines,
        textSize = "14sp",
        layout_marginBottom = "10dp",
      },
      {
        LinearLayout,
        orientation = "horizontal",
        layout_width = "fill",
        layout_marginBottom = "10dp",
        {
          EditText,
          id = "edtSearchWord",
          hint = "Find Word",
          layout_weight = 1,
        },
        {
          Button,
          id = "btnFindLine",
          text = "Find Line",
        },
      },
      {
        LinearLayout,
        orientation = "horizontal",
        layout_width = "fill",
        layout_marginBottom = "10dp",
        {
          EditText,
          id = "edtStartLine",
          hint = "Start Line",
          inputType = "number",
          layout_weight = 1,
        },
        {
          EditText,
          id = "edtEndLine",
          hint = "End Line",
          inputType = "number",
          layout_weight = 1,
        },
      },
      {
        Button,
        id = "btnSelectLines",
        text = "Select",
        layout_width = "fill",
        layout_marginBottom = "12dp",
        textSize = "15sp",
      },
      {
        TextView,
        id = "txtPreviewHeader",
        text = "Selected Code:",
        textSize = "14sp",
        layout_marginBottom = "5dp",
      },
      {
        EditText,
        id = "edtSelectedLinesCode",
        hint = "Selected Code",
        layout_width = "fill",
        layout_height = "160dp",
        gravity = "top",
        layout_marginBottom = "12dp",
      },
      {
        LinearLayout,
        orientation = "horizontal",
        layout_width = "fill",
        layout_marginBottom = "10dp",
        {
          Button,
          id = "btnDeleteLines",
          text = "Delete",
          layout_weight = 1,
        },
        {
          Button,
          id = "btnReplaceSaveLines",
          text = "Replace & Save",
          layout_weight = 1,
        },
      },
      {
        Button,
        id = "btnSyntaxCheck",
        text = "Check Syntax",
        layout_width = "fill",
        layout_marginBottom = "10dp",
      },
      {
        Button,
        id = "btnLineEditorBack",
        text = "Go Back",
        layout_width = "fill",
        layout_marginBottom = "25dp",
        textSize = "16sp",
      },
    }
  }
  
  lineDlg.setView(loadlayout(lineEditorLayout, lViews))
  
  local function validateLineRange()
    local sLine = tonumber(tostring(lViews.edtStartLine.Text))
    local eLine = tonumber(tostring(lViews.edtEndLine.Text))
    if not sLine or not eLine then
      notifyUser("Please enter valid start and end line numbers.", false)
      return nil, nil
    end
    if sLine < 1 or eLine < sLine or eLine > #codeLines then
      notifyUser("Invalid line range. Total lines available: " .. #codeLines, false)
      return nil, nil
    end
    return sLine, eLine
  end
  
  lViews.btnFindLine.onClick = function()
    local query = tostring(lViews.edtSearchWord.Text):lower()
    if query == "" then
      notifyUser("Please enter a word to find.", false)
      return
    end
    local matches = {}
    for i, ln in ipairs(codeLines) do
      if ln:lower():find(query, 1, true) then
        table.insert(matches, i)
        if #matches >= 10 then break end
      end
    end
    if #matches == 0 then
      notifyUser("Word not found in any line.", false)
    else
      lViews.edtStartLine.Text = tostring(matches[1])
      lViews.edtEndLine.Text = tostring(matches[1])
      notifyUser("Found on line: " .. table.concat(matches, ", "), true)
    end
  end
  
  lViews.btnSelectLines.onClick = function()
    local sLine, eLine = validateLineRange()
    if not sLine then return end
    
    local extracted = {}
    for i = sLine, eLine do
      table.insert(extracted, codeLines[i])
    end
    lViews.edtSelectedLinesCode.Text = table.concat(extracted, "\n")
    lViews.txtPreviewHeader.Text = string.format("Selected Lines %d to %d:", sLine, eLine)
    notifyUser(string.format("Selected lines %d to %d loaded.", sLine, eLine), true)
  end
  
  lViews.btnDeleteLines.onClick = function()
    local sLine, eLine = validateLineRange()
    if not sLine then return end
    
    local delConfirmDlg = LuaDialog()
    delConfirmDlg.setTitle("Confirm Delete")
    local dcViews = {}
    
    local delLayout = {
      LinearLayout,
      orientation = "vertical",
      padding = "20dp",
      {
        TextView,
        text = string.format("Are you sure you want to delete Line %d to Line %d?", sLine, eLine),
        textSize = "16sp",
        layout_marginBottom = "20dp",
      },
      {
        LinearLayout,
        orientation = "horizontal",
        layout_width = "fill",
        {
          Button,
          id = "btnConfirmLineDel",
          text = "Confirm Delete",
          layout_weight = 1,
        },
        {
          Button,
          id = "btnCancelLineDel",
          text = "Cancel",
          layout_weight = 1,
        },
      }
    }
    delConfirmDlg.setView(loadlayout(delLayout, dcViews))
    
    dcViews.btnConfirmLineDel.onClick = function()
      local newLines = {}
      for i = 1, #codeLines do
        if i < sLine or i > eLine then
          table.insert(newLines, codeLines[i])
        end
      end
      codeLines = newLines
      local updatedFullCode = table.concat(codeLines, "\n")
      views.edtTextContent.Text = updatedFullCode
      updateCounterDisplay(true)
      
      lViews.txtLineStatus.Text = "Total Lines: " .. #codeLines
      lViews.edtSelectedLinesCode.Text = ""
      delConfirmDlg.dismiss()
      notifyUser(string.format("Lines %d to %d deleted successfully.", sLine, eLine), true)
    end
    
    dcViews.btnCancelLineDel.onClick = function()
      delConfirmDlg.dismiss()
      notifyUser("Delete cancelled.", false)
    end
    
    delConfirmDlg.show()
  end
  
  lViews.btnReplaceSaveLines.onClick = function()
    local sLine, eLine = validateLineRange()
    if not sLine then return end
    
    local replacementText = tostring(lViews.edtSelectedLinesCode.Text):gsub("\r\n", "\n"):gsub("\r", "\n")
    local newLines = {}
    
    for i = 1, sLine - 1 do
      table.insert(newLines, codeLines[i])
    end
    
    for repLine in (replacementText .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(newLines, repLine)
    end
    
    for i = eLine + 1, #codeLines do
      table.insert(newLines, codeLines[i])
    end
    
    codeLines = newLines
    local updatedFullCode = table.concat(codeLines, "\n")
    views.edtTextContent.Text = updatedFullCode
    updateCounterDisplay(true)
    
    lViews.txtLineStatus.Text = "Total Lines: " .. #codeLines
    notifyUser(string.format("Lines %d to %d replaced and saved successfully.", sLine, eLine), true)
  end
  
  lViews.btnSyntaxCheck.onClick = function()
    local currentFull = table.concat(codeLines, "\n")
    local fn, syntaxErr = loadstring(currentFull)
    if fn then
      notifyUser("Syntax Check Passed: Code is 100 percent valid!", true)
    else
      notifyUser("Syntax Error: " .. tostring(syntaxErr), false)
    end
  end
  
  lViews.btnLineEditorBack.onClick = function()
    lineDlg.dismiss()
    notifyUser("Returned to main menu.", true)
  end
  
  lineDlg.show()
end

-- =========================================================================
-- 6. SETTINGS, ABOUT & SUPPORT, AND DESCRIPTION MENUS
-- =========================================================================
local function openAboutSupportMenu()
  local aboutDlg = LuaDialog()
  aboutDlg.setTitle("About and Support")
  local aViews = {}
  
  local aboutLayout = {
    LinearLayout,
    orientation = "vertical",
    padding = "24dp",
    {
      TextView,
      text = "Extension: Smart Code & File Master Pro\nCreator: Mohammad Usman\nWhatsApp: " .. whatsappNumber,
      textSize = "16sp",
      layout_marginBottom = "20dp",
      textIsSelectable = true,
    },
    {
      Button,
      id = "btnCopyNumber",
      text = "Copy Number",
      layout_width = "fill",
      layout_marginBottom = "10dp",
      textSize = "15sp",
    },
    {
      Button,
      id = "btnContactWhatsapp",
      text = "Contact WhatsApp",
      layout_width = "fill",
      layout_marginBottom = "12dp",
      textSize = "15sp",
    },
    {
      Button,
      id = "btnAboutBack",
      text = "Go Back",
      layout_width = "fill",
      textSize = "15sp",
    },
  }
  
  aboutDlg.setView(loadlayout(aboutLayout, aViews))
  
  aViews.btnCopyNumber.onClick = function()
    copyToClipboard(whatsappNumber, "WhatsApp number copied to clipboard.")
  end
  
  aViews.btnContactWhatsapp.onClick = function()
    local url = "https://api.whatsapp.com/send?phone=" .. whatsappNumber:gsub("%+", "")
    local intent = Intent(Intent.ACTION_VIEW)
    intent.setData(Uri.parse(url))
    intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    aboutDlg.dismiss()
    isDialogActive = false
    dlg.dismiss()
    service.startActivity(intent)
    notifyUser("Opening WhatsApp chat with Mohammad Usman.", true)
  end
  
  aViews.btnAboutBack.onClick = function()
    aboutDlg.dismiss()
  end
  
  aboutDlg.show()
end

local function openDescriptionMenu()
  local descDlg = LuaDialog()
  descDlg.setTitle("Description")
  local dViews = {}
  
  local descriptionText = "Assalamu Alaikum! Welcome to Smart Code & File Master Pro, created by Mohammad Usman.\n\n" ..
    "What this extension does:\n" ..
    "1. Unlimited Code & Text Editor: Paste or write unlimited code and view live Characters, Words, and Lines count right after the code box.\n" ..
    "2. Multi-Format File Creator: Save files in Lua, TXT, JSON, XML, HTML, and more inside the Smart_Code_And_File_Master_Pro folder on your phone storage.\n" ..
    "3. Clear Code: Clean extra blank lines and junk spaces from your code safely without losing any word or breaking code syntax.\n" ..
    "4. Browse & Zip Manager: View all phone storage folders, load text into the editor, rename files or folders, compress single or multiple items into a Zip archive, or extract Zip and APK files easily.\n" ..
    "5. Split Code: Divide large scripts into equal line-safe parts for easy copying.\n" ..
    "6. Edit Lines: Search words to find line numbers, select specific lines, and replace or delete them accurately.\n\n" ..
    "How did you like this extension? We hope you find it very useful! Okay, Allah Hafiz!"
  
  local descLayout = {
    ScrollView,
    layout_width = "fill",
    layout_height = "fill",
    fillViewport = true,
    {
      LinearLayout,
      orientation = "vertical",
      padding = "22dp",
      {
        TextView,
        text = descriptionText,
        textSize = "15sp",
        layout_marginBottom = "18dp",
        textIsSelectable = true,
      },
      {
        Button,
        id = "btnReadDesc",
        text = "Read Description Aloud",
        layout_width = "fill",
        layout_marginBottom = "10dp",
      },
      {
        Button,
        id = "btnCopyDesc",
        text = "Copy Description",
        layout_width = "fill",
        layout_marginBottom = "10dp",
      },
      {
        Button,
        id = "btnDescBack",
        text = "Go Back",
        layout_width = "fill",
        layout_marginBottom = "20dp",
      },
    }
  }
  
  descDlg.setView(loadlayout(descLayout, dViews))
  
  service.speak(descriptionText)
  
  dViews.btnReadDesc.onClick = function()
    service.speak(descriptionText)
  end
  
  dViews.btnCopyDesc.onClick = function()
    copyToClipboard(descriptionText, "Description copied to clipboard.")
  end
  
  dViews.btnDescBack.onClick = function()
    descDlg.dismiss()
    notifyUser("Returned to settings.", true)
  end
  
  descDlg.show()
end

local function openSettingsMenu()
  local setDlg = LuaDialog()
  setDlg.setTitle("Settings")
  local stViews = {}
  
  local setLayout = {
    LinearLayout,
    orientation = "vertical",
    padding = "24dp",
    {
      Button,
      id = "btnToggleSound",
      text = "Sound Tone: " .. (soundEnabled and "ON" or "OFF"),
      layout_width = "fill",
      layout_marginBottom = "12dp",
      textSize = "16sp",
    },
    {
      Button,
      id = "btnOpenAbout",
      text = "About and Support",
      layout_width = "fill",
      layout_marginBottom = "12dp",
      textSize = "16sp",
    },
    {
      Button,
      id = "btnOpenDescription",
      text = "Description",
      layout_width = "fill",
      layout_marginBottom = "12dp",
      textSize = "16sp",
    },
    {
      Button,
      id = "btnSettingsBack",
      text = "Go Back",
      layout_width = "fill",
      textSize = "16sp",
    },
  }
  
  setDlg.setView(loadlayout(setLayout, stViews))
  
  stViews.btnToggleSound.onClick = function()
    soundEnabled = not soundEnabled
    saveSettings()
    stViews.btnToggleSound.Text = "Sound Tone: " .. (soundEnabled and "ON" or "OFF")
    if soundEnabled then
      notifyUser("Sound tone turned On.", true)
    else
      service.speak("Sound tone turned Off.")
      Toast.makeText(service, "Sound tone turned Off.", Toast.LENGTH_SHORT).show()
    end
  end
  
  stViews.btnOpenAbout.onClick = function()
    openAboutSupportMenu()
  end
  
  stViews.btnOpenDescription.onClick = function()
    openDescriptionMenu()
  end
  
  stViews.btnSettingsBack.onClick = function()
    setDlg.dismiss()
    notifyUser("Returned to main menu.", true)
  end
  
  setDlg.show()
end

-- =========================================================================
-- 7. MAIN MENU LAYOUT & CONTROLS (Clean Hints, Simple Names, Exact Order)
-- =========================================================================
local mainScrollLayout = {
  ScrollView,
  layout_width = "fill",
  layout_height = "fill",
  fillViewport = true,
  {
    LinearLayout,
    orientation = "vertical",
    padding = "22dp",
    -- 1. Extension Name Only (No Creator Name in Header)
    {
      TextView,
      id = "txtHeaderTitle",
      text = "Smart Code & File Master Pro",
      textSize = "17sp",
      gravity = "center",
      layout_marginBottom = "14dp",
    },
    -- 2. File Name EditBox (Simple Hint)
    {
      EditText,
      id = "edtFileName",
      hint = "Enter File Name",
      layout_width = "fill",
      layout_marginBottom = "10dp",
    },
    -- 3. File Category Selector (Default .lua)
    {
      LinearLayout,
      orientation = "horizontal",
      layout_width = "fill",
      gravity = "center_vertical",
      layout_marginBottom = "10dp",
      {
        TextView,
        text = "Category: ",
        textSize = "15sp",
      },
      {
        Spinner,
        id = "spnFileCategory",
        layout_weight = 1,
      },
    },
    -- 4. Unlimited Code / Text EditBox (Simple Hint)
    {
      EditText,
      id = "edtTextContent",
      hint = "Paste Code or Text",
      layout_width = "fill",
      layout_height = "175dp",
      gravity = "top",
      layout_marginBottom = "8dp",
    },
    -- 5. Live Character, Word & Line Counter (Placed right after Code EditBox)
    {
      TextView,
      id = "txtCounter",
      text = "Characters: 0 | Words: 0 | Lines: 0 | Format: .lua",
      textSize = "14sp",
      layout_marginBottom = "14dp",
    },
    -- 6. Simple Action Buttons
    {
      Button,
      id = "btnCleanCode",
      text = "Clear Code",
      layout_width = "fill",
      layout_marginBottom = "8dp",
      textSize = "15sp",
    },
    {
      Button,
      id = "btnCopyText",
      text = "Copy",
      layout_width = "fill",
      layout_marginBottom = "8dp",
      textSize = "15sp",
    },
    {
      Button,
      id = "btnCreateFile",
      text = "Create File",
      layout_width = "fill",
      layout_marginBottom = "8dp",
      textSize = "15sp",
    },
    {
      Button,
      id = "btnBrowseFiles",
      text = "Browse",
      layout_width = "fill",
      layout_marginBottom = "8dp",
      textSize = "15sp",
    },
    {
      Button,
      id = "btnSplitScript",
      text = "Split Code",
      layout_width = "fill",
      layout_marginBottom = "8dp",
      textSize = "15sp",
    },
    {
      Button,
      id = "btnEditLines",
      text = "Edit Lines",
      layout_width = "fill",
      layout_marginBottom = "8dp",
      textSize = "15sp",
    },
    {
      Button,
      id = "btnSettings",
      text = "Settings",
      layout_width = "fill",
      layout_marginBottom = "8dp",
      textSize = "15sp",
    },
    {
      Button,
      id = "btnCloseExtension",
      text = "Close",
      layout_width = "fill",
      layout_marginBottom = "22dp",
      textSize = "15sp",
    },
  }
}

dlg.setView(loadlayout(mainScrollLayout, views))

-- Setup Category Spinner (Default .lua at index 0)
local catAdapter = ArrayAdapter(service, android.R.layout.simple_spinner_dropdown_item, fileCategories)
views.spnFileCategory.Adapter = catAdapter
views.spnFileCategory.setSelection(0)

views.spnFileCategory.onItemSelected = function(parent, view, position, id)
  selectedExtension = fileCategories[position + 1]
  updateCounterDisplay(true)
end

-- Accessibility Initial Focus
views.txtHeaderTitle.requestFocus()
views.txtHeaderTitle.sendAccessibilityEvent(AccessibilityEvent.TYPE_VIEW_FOCUSED)

-- Button 1: Clear Code
views.btnCleanCode.onClick = function()
  local raw = tostring(views.edtTextContent.Text)
  if raw == "" then
    notifyUser("There is no code to clear.", false)
    return
  end
  local beforeChars = #raw
  local cleaned = cleanCodeSafely(raw)
  local afterChars = #cleaned
  views.edtTextContent.Text = cleaned
  updateCounterDisplay(true)
  local removed = math.max(0, beforeChars - afterChars)
  notifyUser("Code cleaned successfully. Removed " .. removed .. " extra junk characters.", true)
end

-- Button 2: Copy
views.btnCopyText.onClick = function()
  updateCounterDisplay(true)
  local currentText = tostring(views.edtTextContent.Text)
  copyToClipboard(currentText, "Code copied to clipboard.")
end

-- Button 3: Create File
views.btnCreateFile.onClick = function()
  updateCounterDisplay(true)
  local rawName = tostring(views.edtFileName.Text)
  local cleanName = sanitizeFileName(rawName)
  local fContent = tostring(views.edtTextContent.Text)
  
  if cleanName == "" then
    notifyUser("Please enter a file name first.", false)
    return
  end
  if fContent == "" then
    notifyUser("Please paste or write some code first.", false)
    return
  end
  
  cleanName = cleanName:gsub("%.%w+$", "")
  local finalFileName = cleanName .. selectedExtension
  local fullFilePath = pluginFolder .. finalFileName
  local targetFile = File(fullFilePath)
  
  if targetFile.exists() then
    local overwriteDlg = LuaDialog()
    overwriteDlg.setTitle("File Already Exists")
    local oViews = {}
    local overLayout = {
      LinearLayout,
      orientation = "vertical",
      padding = "20dp",
      {
        TextView,
        text = "File '" .. finalFileName .. "' already exists. Do you want to overwrite it?",
        textSize = "15sp",
        layout_marginBottom = "18dp",
      },
      {
        LinearLayout,
        orientation = "horizontal",
        layout_width = "fill",
        {
          Button,
          id = "btnConfirmOverwrite",
          text = "Overwrite",
          layout_weight = 1,
        },
        {
          Button,
          id = "btnCancelOverwrite",
          text = "Cancel",
          layout_weight = 1,
        },
      }
    }
    overwriteDlg.setView(loadlayout(overLayout, oViews))
    
    oViews.btnConfirmOverwrite.onClick = function()
      local ok, err = writeFileFast(fullFilePath, fContent)
      overwriteDlg.dismiss()
      if ok then
        notifyUser("File overwritten successfully: " .. finalFileName, true)
      else
        notifyUser("Error saving file: " .. tostring(err), false)
      end
    end
    
    oViews.btnCancelOverwrite.onClick = function()
      overwriteDlg.dismiss()
      notifyUser("Cancelled.", false)
    end
    overwriteDlg.show()
    return
  end
  
  local ok, err = writeFileFast(fullFilePath, fContent)
  if ok then
    notifyUser("File created successfully: " .. finalFileName, true)
  else
    notifyUser("Failed to create file: " .. tostring(err), false)
  end
end

-- Button 4: Browse (Opens Phone Storage directly)
views.btnBrowseFiles.onClick = function()
  openFileBrowser(rootStorage)
end

-- Button 5: Split Code
views.btnSplitScript.onClick = function()
  updateCounterDisplay(true)
  openCodeSplitterWindow()
end

-- Button 6: Edit Lines
views.btnEditLines.onClick = function()
  updateCounterDisplay(true)
  openLineEditorWindow()
end

-- Button 7: Settings
views.btnSettings.onClick = function()
  openSettingsMenu()
end

-- Button 8: Close
views.btnCloseExtension.onClick = function()
  isDialogActive = false
  notifyUser("Closing Smart Code and File Master Pro.", true)
  dlg.dismiss()
end

dlg.show()
