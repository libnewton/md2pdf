local callouts = {
  success = "Success",
  warning = "Warning",
  tip = "Tip",
  info = "Info",
}

local function load_data_file(name)
  local ok, loaded = pcall(dofile, name)
  if ok and type(loaded) == "table" then
    return loaded
  end

  return {}
end

local emoji_data = load_data_file("pdf-fixes-emoji-map.lua")
local twemoji_map = emoji_data.map or {}
local twemoji_max_sequence_length = emoji_data.max_sequence_length or 0


local function maybe_apply_dimensions(el)
  local title = el.title or ""
  local width, height = title:match("^%s*=(%d+)x(%d*)%s*$")
  el.attributes = el.attributes or {}

  if width then
    el.attributes.width = width .. "px"
    if height and height ~= "" then
      el.attributes.height = height .. "px"
    else
      el.attributes.height = nil
    end
    el.title = ""
  elseif not el.attributes.width then
    el.attributes.width = "85%"
  end
  return el
end

local function is_ignorable_inline(el)
  return el.t == "Space"
    or el.t == "SoftBreak"
    or el.t == "LineBreak"
    or (el.t == "Str" and (el.text == "" or el.text == "\\n"))
end

local function trim_inlines(inlines)
  while #inlines > 0 and is_ignorable_inline(inlines[1]) do
    inlines:remove(1)
  end

  while #inlines > 0 and is_ignorable_inline(inlines[#inlines]) do
    inlines:remove(#inlines)
  end

  return inlines
end

local function trim_text(text)
  return text:gsub("^%s+", ""):gsub("%s+$", "")
end

local function has_class(el, class_name)
  for _, class in ipairs(el.classes) do
    if class == class_name then
      return true
    end
  end
  return false
end

local function is_paragraphish(block)
  return block.t == "Para" or block.t == "Plain"
end

local function twemoji_sequence_key(codepoints, start_index, count)
  local parts = {}
  for offset = 0, count - 1 do
    parts[#parts + 1] = string.format("%x", codepoints[start_index + offset])
  end
  return table.concat(parts, "-")
end

local function emoji_page_at(codepoints, start_index)
  if next(twemoji_map) == nil then
    return nil, 0
  end

  local remaining = #codepoints - start_index + 1
  local max_length = math.min(twemoji_max_sequence_length, remaining)
  local page = nil
  local length = 0

  for count = 1, max_length do
    local candidate = twemoji_sequence_key(codepoints, start_index, count)
    if twemoji_map[candidate] then
      page = twemoji_map[candidate]
      length = count
    end
  end

  return page, length
end

local function should_skip_emoji_codepoint(codepoint)
  return codepoint == 0x200D
    or codepoint == 0xFE0E
    or codepoint == 0xFE0F
    or codepoint == 0x20E3
    or (codepoint >= 0x1F3FB and codepoint <= 0x1F3FF)
    or (codepoint >= 0xE0020 and codepoint <= 0xE007F)
end

local function blocks_to_latex(blocks)
  return trim_text(pandoc.write(pandoc.Pandoc(blocks), "latex"))
end

local function inlines_to_latex(inlines)
  if not inlines or #inlines == 0 then
    return ""
  end

  return blocks_to_latex({ pandoc.Plain(inlines) })
end

local function parse_image_attributes(text)
  local attrs = {}
  local body = trim_text(text or "")

  local width, height = body:match("^=(%d+)x(%d*)$")
  if width then
    attrs.width = width .. "px"
    if height and height ~= "" then
      attrs.height = height .. "px"
    end
    return attrs
  end

  local brace_body = body:match("^%{(.*)%}$")
  if not brace_body then
    return nil
  end

  for key, value in brace_body:gmatch("([%w-]+)%s*=%s*([^%s}]+)") do
    attrs[key] = value
  end

  if next(attrs) then
    return attrs
  end

  return nil
end

local function apply_image_attributes(el, attrs)
  if not attrs then
    return el
  end

  el.attributes = el.attributes or {}
  for key, value in pairs(attrs) do
    el.attributes[key] = value
  end

  return el
end

local function consume_trailing_image_attributes(image, inlines)
  local text = trim_text(pandoc.utils.stringify(inlines))
  local attrs = parse_image_attributes(text)
  if not attrs then
    return image, inlines
  end

  image = apply_image_attributes(image, attrs)
  return image, pandoc.List:new()
end

local function normalize_dimension(value)
  if not value or value == "" then
    return nil
  end

  local trimmed = trim_text(value)
  local percent = trimmed:match("^(%d+%.?%d*)%%$")
  if percent then
    local factor = tonumber(percent) / 100
    if math.abs(factor - 1) < 0.0001 then
      return "\\linewidth"
    end
    return string.format("%.4f\\linewidth", factor)
  end

  local px = trimmed:match("^(%d+%.?%d*)px$")
  if px then
    return string.format("%.4fbp", tonumber(px) * 72 / 96)
  end

  if trimmed:match("^%d+%.?%d*$") then
    return trimmed .. "bp"
  end

  return trimmed
end

local function graphics_path(src)
  return "\\detokenize{" .. tostring(src or "") .. "}"
end

local function image_to_latex(el)
  local options = {}
  local width = normalize_dimension(el.attributes and el.attributes.width)
  local height = normalize_dimension(el.attributes and el.attributes.height)

  if width then
    options[#options + 1] = "width=" .. width
  end

  if height then
    options[#options + 1] = "height=" .. height
  end

  if width and height then
    options[#options + 1] = "keepaspectratio"
  end

  local option_text = ""
  if #options > 0 then
    option_text = "[" .. table.concat(options, ",") .. "]"
  end

  return "\\includegraphics" .. option_text .. "{" .. graphics_path(el.src) .. "}"
end

local function centered_image_blocks(image)
  if FORMAT:match("latex") then
    local lines = {
      "\\begin{center}",
      image_to_latex(image),
    }

    local caption = inlines_to_latex(image.caption)
    if caption ~= "" then
      lines[#lines + 1] = "\\par\\vspace{0.18em}"
      lines[#lines + 1] = "{\\fontsize{8.6pt}{10pt}\\selectfont\\color{black!62} " .. caption .. "\\par}"
    end

    lines[#lines + 1] = "\\end{center}"
    return { pandoc.RawBlock("latex", table.concat(lines, "\n")) }
  end

  return {
    pandoc.RawBlock("latex", "\\begin{center}"),
    pandoc.Plain({ image }),
    pandoc.RawBlock("latex", "\\end{center}"),
  }
end

local function cell_to_latex(cell)
  local parts = {}
  for _, block in ipairs(cell.contents) do
    local part = blocks_to_latex({ block })
    if part ~= "" then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, " \\par ")
end

local function alignment_spec(col_count)
  local specs = {}
  for _ = 1, col_count do
    specs[#specs + 1] = ">{\\raggedright\\arraybackslash}l"
  end
  return table.concat(specs, "|")
end

local function row_to_latex(row, is_header, has_rule)
  local cells = {}
  for _, cell in ipairs(row.cells) do
    local content = cell_to_latex(cell)
    if is_header and content ~= "" then
      content = "\\textbf{" .. content .. "}"
    end
    cells[#cells + 1] = content
  end

  local prefix = is_header and "\\rowcolor{tableheaderbg} " or ""
  local suffix = has_rule and " \\\\ \\hline" or " \\\\"
  return prefix .. table.concat(cells, " & ") .. suffix
end

local function collect_body_rows(bodies)
  local rows = {}
  for _, body in ipairs(bodies) do
    if body.head then
      for _, row in ipairs(body.head) do
        rows[#rows + 1] = row
      end
    end
    if body.body then
      for _, row in ipairs(body.body) do
        rows[#rows + 1] = row
      end
    end
  end
  return rows
end

local function render_table_latex(el)
  local header_rows = el.head and el.head.rows or {}
  local body_rows = collect_body_rows(el.bodies or {})
  local foot_rows = el.foot and el.foot.rows or {}
  local all_rows = {}

  for _, row in ipairs(header_rows) do
    all_rows[#all_rows + 1] = row
  end
  for _, row in ipairs(body_rows) do
    all_rows[#all_rows + 1] = row
  end
  for _, row in ipairs(foot_rows) do
    all_rows[#all_rows + 1] = row
  end

  if #all_rows == 0 then
    return nil
  end

  local col_count = #all_rows[1].cells
  if col_count == 0 then
    return nil
  end

  local lines = {
    "{",
    "\\arrayrulecolor{table-rule-color}",
    "\\setlength{\\arrayrulewidth}{0.4pt}",
    "\\setlength{\\tabcolsep}{6pt}",
    "\\renewcommand{\\arraystretch}{1.22}",
    "\\sbox{\\pandocTableBox}{%",
    "\\begin{tabular}{" .. alignment_spec(col_count) .. "}",
  }

  if #header_rows > 0 then
    for i, row in ipairs(header_rows) do
      local has_rule = i < #header_rows or #body_rows > 0 or #foot_rows > 0
      lines[#lines + 1] = row_to_latex(row, true, has_rule)
    end
  end

  for i, row in ipairs(body_rows) do
    local has_rule = i < #body_rows or #foot_rows > 0
    lines[#lines + 1] = row_to_latex(row, false, has_rule)
  end

  for i, row in ipairs(foot_rows) do
    local has_rule = i < #foot_rows
    lines[#lines + 1] = row_to_latex(row, false, has_rule)
  end

  lines[#lines + 1] = "\\end{tabular}%"
  lines[#lines + 1] = "}"
  lines[#lines + 1] = "\\ifdim\\wd\\pandocTableBox>\\linewidth"
  lines[#lines + 1] = "\\begin{tcolorbox}[enhanced,width=\\linewidth,colback=white,colframe=table-rule-color,boxrule=0.4pt,arc=1mm,left=0.5pt,right=0.5pt,top=0.5pt,bottom=0.5pt,boxsep=0pt]"
  lines[#lines + 1] = "\\resizebox{\\linewidth}{!}{\\usebox{\\pandocTableBox}}"
  lines[#lines + 1] = "\\end{tcolorbox}"
  lines[#lines + 1] = "\\else"
  lines[#lines + 1] = "\\noindent\\tcbox[enhanced,nobeforeafter,colback=white,colframe=table-rule-color,boxrule=0.4pt,arc=1mm,left=0.5pt,right=0.5pt,top=0.5pt,bottom=0.5pt,boxsep=0pt]{\\usebox{\\pandocTableBox}}"
  lines[#lines + 1] = "\\fi"
  lines[#lines + 1] = "}"

  return table.concat(lines, "\n")
end

local function latex_label_for_header(header)
  if not header.identifier or header.identifier == "" then
    return ""
  end

  return "\\phantomsection\\label{" .. header.identifier .. "}"
end

local function koma_font_for_level(level)
  local fonts = {
    [1] = "section",
    [2] = "subsection",
    [3] = "subsubsection",
    [4] = "paragraph",
    [5] = "subparagraph",
    [6] = "subparagraph",
  }

  return fonts[level] or "subparagraph"
end

local function set_ordered_list_style(el, depth)
  local start = el.start or 1
  if el.listAttributes and el.listAttributes[1] then
    start = el.listAttributes[1]
  end

  local style = "Decimal"
  local delimiter = "Period"
  if depth == 2 then
    style = "LowerAlpha"
    delimiter = "OneParen"
  elseif depth >= 3 then
    style = "LowerRoman"
    delimiter = "OneParen"
  end

  el.style = style
  el.delimiter = delimiter
  el.listAttributes = { start, style, delimiter }
  return el
end

local function make_highlight_span(inlines)
  return pandoc.Span(inlines, pandoc.Attr("", { "md-highlight" }, {}))
end

local function parse_highlight_inlines(inlines)
  local out = pandoc.List:new()
  local current = nil
  local changed = false

  local function append_inline(inline)
    if current then
      current:insert(inline)
    else
      out:insert(inline)
    end
  end

  local function append_text(text)
    if text ~= "" then
      append_inline(pandoc.Str(text))
    end
  end

  for _, inline in ipairs(inlines) do
    if inline.t == "Str" then
      local text = inline.text
      local pos = 1

      while true do
        local marker = text:find("==", pos, true)
        if not marker then
          append_text(text:sub(pos))
          break
        end

        append_text(text:sub(pos, marker - 1))
        if current then
          out:insert(make_highlight_span(current))
          current = nil
          changed = true
        else
          current = pandoc.List:new()
        end
        pos = marker + 2
      end
    else
      append_inline(inline)
    end
  end

  if current then
    out:insert(pandoc.Str("=="))
    for _, inline in ipairs(current) do
      out:insert(inline)
    end
  end

  if changed then
    return out
  end

  return nil
end

local function is_spoiler_fence_text(text)
  return text:match("^%+%+%+%+%+%+*$") ~= nil
end

local function spoiler_open_title(block)
  if not is_paragraphish(block) then
    return nil
  end

  local first = block.content and block.content[1]
  if not first or first.t ~= "Str" or not is_spoiler_fence_text(first.text) then
    return nil
  end

  local title = pandoc.List:new()
  for i = 2, #block.content do
    title:insert(block.content[i])
  end
  trim_inlines(title)

  if #title == 0 then
    return nil
  end

  return title
end

local function is_spoiler_open_fence(block)
  if not is_paragraphish(block) then
    return false
  end

  return is_spoiler_fence_text(trim_text(pandoc.utils.stringify(block.content)))
end

local function is_spoiler_close(block)
  if not is_paragraphish(block) then
    return false
  end

  return is_spoiler_fence_text(trim_text(pandoc.utils.stringify(block.content)))
end

local function split_block_lines(block)
  if not is_paragraphish(block) then
    return nil
  end

  local lines = {}
  local current = pandoc.List:new()
  local has_break = false

  for _, inline in ipairs(block.content) do
    if inline.t == "SoftBreak" or inline.t == "LineBreak" then
      lines[#lines + 1] = current
      current = pandoc.List:new()
      has_break = true
    else
      current:insert(inline)
    end
  end

  lines[#lines + 1] = current

  if not has_break then
    return nil
  end

  local has_fence = false
  for _, line in ipairs(lines) do
    if is_spoiler_fence_text(trim_text(pandoc.utils.stringify(line))) then
      has_fence = true
      break
    end
  end

  if not has_fence then
    return nil
  end

  local out = pandoc.List:new()
  for _, line in ipairs(lines) do
    trim_inlines(line)
    if #line > 0 then
      out:insert(pandoc.Para(line))
    end
  end

  return out
end

local function expand_spoiler_line_blocks(blocks)
  local out = pandoc.List:new()

  for _, block in ipairs(blocks) do
    local expanded = split_block_lines(block)
    if expanded then
      for _, split_block in ipairs(expanded) do
        out:insert(split_block)
      end
    else
      out:insert(block)
    end
  end

  return out
end

local function make_spoiler_blocks(title, body)
  local title_latex = inlines_to_latex(title)
  local out = pandoc.List:new({
    pandoc.RawBlock("latex", "\\noindent\\(\\blacktriangleright\\)\\enspace " .. title_latex .. "\\par"),
    pandoc.RawBlock("latex", "\\begin{mdspoilerbody}"),
  })

  for _, block in ipairs(body) do
    out:insert(block)
  end

  out:insert(pandoc.RawBlock("latex", "\\end{mdspoilerbody}"))
  return out
end

local function transform_spoilers_in_blocks(blocks)
  blocks = expand_spoiler_line_blocks(blocks)
  local out = pandoc.List:new()
  local i = 1

  while i <= #blocks do
    local title = spoiler_open_title(blocks[i])
    local body_start = i + 1

    if not title and is_spoiler_open_fence(blocks[i]) then
      local next_block = blocks[i + 1]
      if next_block and is_paragraphish(next_block) and not is_spoiler_close(next_block) then
        title = next_block.content
        body_start = i + 2
      end
    end

    if title then
      local j = body_start
      while j <= #blocks and not is_spoiler_close(blocks[j]) do
        j = j + 1
      end

      if j <= #blocks then
        local body = pandoc.List:new()
        for k = body_start, j - 1 do
          body:insert(blocks[k])
        end

        for _, block in ipairs(make_spoiler_blocks(title, body)) do
          out:insert(block)
        end
        i = j + 1
      else
        out:insert(blocks[i])
        i = i + 1
      end
    else
      out:insert(blocks[i])
      i = i + 1
    end
  end

  return out
end

local function transform_block_list(blocks, list_depth)
  for i, block in ipairs(blocks) do
    if block.t == "OrderedList" then
      block = set_ordered_list_style(block, list_depth + 1)
      for j, item in ipairs(block.content) do
        block.content[j] = transform_block_list(item, list_depth + 1)
      end
      blocks[i] = block
    elseif block.t == "BulletList" then
      for j, item in ipairs(block.content) do
        block.content[j] = transform_block_list(item, list_depth + 1)
      end
      blocks[i] = block
    elseif block.t == "BlockQuote" or block.t == "Div" then
      block.content = transform_block_list(block.content, list_depth)
      blocks[i] = block
    end
  end

  return transform_spoilers_in_blocks(blocks)
end

function Pandoc(doc)
  if not FORMAT:match("latex") then
    return doc
  end

  doc.blocks = transform_block_list(doc.blocks, 0)
  return doc
end

-- Map of Unicode codepoints to LaTeX replacements.
-- Characters listed here will be substituted at the Pandoc AST level so that
-- LaTeX never sees the raw UTF-8 bytes (which would cause inputenc errors).
-- Characters NOT in this table but above U+007F are replaced with a safe
-- placeholder so that compilation always succeeds.
local unicode_to_latex = load_data_file("pdf-fixes-unicode-map.lua")


-- Characters in the Latin-1 supplement (U+00C0..U+00FF) are generally handled
-- by T1 fontenc + inputenc utf8, so we only need to worry about codepoints
-- above that range (plus a few specific ones already in the table above).
local function replace_unicode_for_latex(text)
  local codepoints = {}
  for _, codepoint in utf8.codes(text) do
    codepoints[#codepoints + 1] = codepoint
  end

  local out = {}
  local changed = false
  local i = 1

  while i <= #codepoints do
    local page, length = emoji_page_at(codepoints, i)
    if page then
      out[#out + 1] = "\\mdemoji{" .. tostring(page) .. "}"
      changed = true
      i = i + length
    else
      local codepoint = codepoints[i]
      local replacement = unicode_to_latex[codepoint]
      if replacement then
        out[#out + 1] = replacement
        changed = true
      elseif should_skip_emoji_codepoint(codepoint) then
        changed = true
      elseif codepoint > 0x024F then
        -- Beyond Latin Extended-B: not safe for inputenc, replace with placeholder
        out[#out + 1] = "?"
        changed = true
      else
        out[#out + 1] = utf8.char(codepoint)
      end
      i = i + 1
    end
  end

  if changed then
    return table.concat(out)
  end
  return nil
end

function Str(el)
  if not FORMAT:match("latex") then
    return nil
  end

  if el.text == "\\n" then
    return {}
  end

  local replaced = replace_unicode_for_latex(el.text)
  if replaced then
    return pandoc.RawInline("latex", replaced)
  end
end

function Math(el)
  if not FORMAT:match("latex") then
    return nil
  end

  local text = el.text
  if text:find("\\LaTeX") then
    text = text:gsub("\\LaTeX", "\\text{\\LaTeX{}}")
    el.text = text
    return el
  end
end

function Inlines(inlines)
  if not FORMAT:match("latex") then
    return nil
  end

  return parse_highlight_inlines(inlines)
end

local function is_highlight_span(el)
  return el.t == "Span" and has_class(el, "md-highlight")
end

function Span(el)
  if not FORMAT:match("latex") or not is_highlight_span(el) then
    return nil
  end

  return pandoc.RawInline("latex", "\\mdhighlight{" .. inlines_to_latex(el.content) .. "}")
end

function Strikeout(el)
  if not FORMAT:match("latex") then
    return nil
  end

  local content = parse_highlight_inlines(el.content) or el.content
  local has_highlight = false
  for _, inline in ipairs(content) do
    if is_highlight_span(inline) then
      has_highlight = true
      break
    end
  end

  if not has_highlight then
    return nil
  end

  local pieces = {}
  local buffer = pandoc.List:new()

  local function flush_buffer()
    if #buffer == 0 then
      return
    end
    pieces[#pieces + 1] = "\\st{" .. inlines_to_latex(buffer) .. "}"
    buffer = pandoc.List:new()
  end

  for _, inline in ipairs(content) do
    if is_highlight_span(inline) then
      flush_buffer()
      pieces[#pieces + 1] = "\\mdhighlight{\\st{" .. inlines_to_latex(inline.content) .. "}}"
    elseif inline.t == "Space" then
      flush_buffer()
      pieces[#pieces + 1] = " "
    elseif inline.t == "SoftBreak" or inline.t == "LineBreak" then
      flush_buffer()
      pieces[#pieces + 1] = "\\linebreak{}"
    else
      buffer:insert(inline)
    end
  end

  flush_buffer()
  return pandoc.RawInline("latex", table.concat(pieces))
end

local function escape_inline_code(text)
  local replacements = {
    ["\\"] = "\\textbackslash{}",
    ["{"] = "\\{",
    ["}"] = "\\}",
    ["#"] = "\\#",
    ["$"] = "\\$",
    ["%"] = "\\%",
    ["&"] = "\\&",
    ["_"] = "\\_",
    ["~"] = "\\textasciitilde{}",
    ["^"] = "\\textasciicircum{}",
  }

  local out = {}
  for _, codepoint in utf8.codes(text) do
    local ch = utf8.char(codepoint)
    if replacements[ch] then
      out[#out + 1] = replacements[ch]
    elseif unicode_to_latex[codepoint] then
      out[#out + 1] = unicode_to_latex[codepoint]
    elseif codepoint > 0x024F then
      out[#out + 1] = "?"
    else
      out[#out + 1] = ch
    end
  end
  return table.concat(out)
end

function Code(el)
  if not FORMAT:match("latex") then
    return nil
  end

  return pandoc.RawInline("latex", "\\inlinecode{" .. escape_inline_code(el.text) .. "}")
end

function CodeBlock(el)
  if not FORMAT:match("latex") then
    return nil
  end

  if not has_class(el, "numberLines") then
    el.classes:insert("numberLines")
  end

  return el
end

function Image(el)
  el = maybe_apply_dimensions(el)
  if FORMAT:match("latex") then
    el.caption = pandoc.Inlines({})
    el.attributes = el.attributes or {}
    el.attributes.alt = nil
  end
  return el
end

function Para(el)
  local image_index = nil
  local image_count = 0

  for i, inline in ipairs(el.content) do
    if inline.t == "Image" then
      image_index = i
      image_count = image_count + 1
    end
  end

  if image_count ~= 1 then
    return nil
  end

  local before = pandoc.List:new()
  local after = pandoc.List:new()

  for i = 1, image_index - 1 do
    before:insert(el.content[i])
  end

  for i = image_index + 1, #el.content do
    after:insert(el.content[i])
  end

  trim_inlines(before)
  trim_inlines(after)

  local image = maybe_apply_dimensions(el.content[image_index])
  image, after = consume_trailing_image_attributes(image, after)
  image = maybe_apply_dimensions(image)

  if #before == 0 and #after == 0 then
    return centered_image_blocks(image)
  end

  local blocks = pandoc.List:new()
  if #before > 0 then
    blocks:insert(pandoc.Para(before))
  end

  for _, block in ipairs(centered_image_blocks(image)) do
    blocks:insert(block)
  end

  if #after > 0 then
    blocks:insert(pandoc.Para(after))
  end

  return blocks
end

function BlockQuote(el)
  if not FORMAT:match("latex") then
    return nil
  end

  if #el.content ~= 1 or el.content[1].t ~= "Header" then
    return nil
  end

  local header = el.content[1]
  local header_latex = blocks_to_latex({ pandoc.Plain(header.content) })
  local font_name = koma_font_for_level(header.level)
  local label = latex_label_for_header(header)
  return pandoc.RawBlock(
    "latex",
    "\\begin{tightblockquoteheading}\n" ..
      label ..
      "\\noindent{\\usekomafont{" .. font_name .. "}\\fontseries{sb}\\selectfont " ..
      header_latex ..
      "\\par}\n\\end{tightblockquoteheading}"
  )
end

function Table(el)
  if not FORMAT:match("latex") then
    return nil
  end

  local latex = render_table_latex(el)
  if not latex then
    return el
  end

  return pandoc.RawBlock("latex", latex)
end

function Div(el)
  if not FORMAT:match("latex") then
    return nil
  end

  local class_name = nil
  for _, class in ipairs(el.classes) do
    if callouts[class] then
      class_name = class
      break
    end
  end

  if not class_name then
    return nil
  end

  local blocks = pandoc.List:new(el.content)
  local title = pandoc.Inlines({ pandoc.Str(callouts[class_name]) })

  if #blocks > 0 and blocks[1].t == "Header" then
    title = blocks[1].content
    blocks:remove(1)
  end

  blocks:insert(1, pandoc.Para({ pandoc.Strong(title) }))

  local env = class_name .. "box"
  local out = pandoc.List:new({ pandoc.RawBlock("latex", "\\begin{" .. env .. "}") })
  for _, block in ipairs(blocks) do
    out:insert(block)
  end
  out:insert(pandoc.RawBlock("latex", "\\end{" .. env .. "}"))
  return out
end

local function get_task_checkbox_cp(item)
  local first_block = item[1]
  if not first_block then
    return nil
  end
  if first_block.t ~= "Plain" and first_block.t ~= "Para" then
    return nil
  end
  local first_inline = first_block.content[1]
  if not first_inline or first_inline.t ~= "Str" then
    return nil
  end
  local cp = utf8.codepoint(first_inline.text, 1, 1)
  if cp == 0x2610 or cp == 0x2611 or cp == 0x2612 then
    return cp
  end
  return nil
end

local function strip_task_checkbox(item)
  local first_block = item[1]
  local inlines = first_block.content
  local text = inlines[1].text

  -- Remove the first codepoint (the checkbox character)
  local rest = ""
  local skipped = false
  for _, c in utf8.codes(text) do
    if skipped then
      rest = rest .. utf8.char(c)
    else
      skipped = true
    end
  end

  if rest == "" then
    inlines:remove(1)
  else
    inlines[1] = pandoc.Str(rest)
  end

  -- Remove leading space after checkbox
  if #inlines > 0 and inlines[1].t == "Space" then
    inlines:remove(1)
  end
end

function BulletList(el)
  if not FORMAT:match("latex") then
    return nil
  end

  local has_tasks = false
  for _, item in ipairs(el.content) do
    if get_task_checkbox_cp(item) then
      has_tasks = true
      break
    end
  end

  if not has_tasks then
    return nil
  end

  local blocks = pandoc.List:new()
  blocks:insert(pandoc.RawBlock("latex", "\\begin{itemize}\\tightlist"))

  for _, item in ipairs(el.content) do
    local cp = get_task_checkbox_cp(item)
    if cp then
      local checkbox = (cp == 0x2610) and "\\mdcheckbox" or "\\mdcheckboxchecked"
      strip_task_checkbox(item)
      blocks:insert(pandoc.RawBlock("latex", "\\item[" .. checkbox .. "]"))
    else
      blocks:insert(pandoc.RawBlock("latex", "\\item"))
    end
    for _, block in ipairs(item) do
      blocks:insert(block)
    end
  end

  blocks:insert(pandoc.RawBlock("latex", "\\end{itemize}"))
  return blocks
end

function RawBlock(el)
  if not FORMAT:match("latex") or el.format ~= "latex" then
    return nil
  end

  local text = el.text
  text = text:gsub("\\hypersetup%{%s*hidelinks,%s*breaklinks=true,", "\\hypersetup{colorlinks=true,breaklinks=true,", 1)
  return pandoc.RawBlock("latex", text)
end

return {
  traverse = "topdown",
  Pandoc = Pandoc,
  Inlines = Inlines,
  Str = Str,
  Math = Math,
  Span = Span,
  Strikeout = Strikeout,
  Code = Code,
  CodeBlock = CodeBlock,
  Image = Image,
  Para = Para,
  BulletList = BulletList,
  BlockQuote = BlockQuote,
  Table = Table,
  Div = Div,
  RawBlock = RawBlock,
}
