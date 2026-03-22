local callouts = {
  success = "Success",
  warning = "Warning",
  tip = "Tip",
  info = "Info",
}

local latex_preamble = [[
\hypersetup{%
  linkcolor=linktextblue,
  urlcolor=linktextblue,
  citecolor=linktextblue,
  filecolor=linktextblue
}
\renewcommand{\textbf}[1]{{\fontseries{sb}\selectfont #1}}
\addtokomafont{disposition}{\fontseries{sb}\selectfont}
\renewcommand{\labelitemi}{\raisebox{0.15ex}{\normalsize$\bullet$}}
\renewcommand{\labelitemii}{\textopenbullet}
\renewcommand{\labelitemiii}{\raisebox{0.28ex}{\rule{0.5ex}{0.5ex}}}
\renewcommand{\labelitemiv}{\raisebox{0.28ex}{\rule{0.5ex}{0.5ex}}}
\setlist[enumerate,1]{label=\arabic*.,leftmargin=*}
\setlist[enumerate,2]{label=\alph*),leftmargin=*}
\setlist[enumerate,3]{label=\roman*),leftmargin=*}
\setlist[enumerate,4]{label=\roman*),leftmargin=*}
\setlist[itemize,2]{label=\textopenbullet}
\setlist[itemize,3]{label=\raisebox{0.28ex}{\rule{0.5ex}{0.5ex}}}
\setlist[itemize,4]{label=\raisebox{0.28ex}{\rule{0.5ex}{0.5ex}}}
\definecolor{inlinecodefg}{HTML}{000000}
\renewtcbox{\inlinecodebox}{
  on line,
  box align=base,
  nobeforeafter,
  enhanced,
  colback=inlinecodebg,
  colframe=inlinecodebg,
  coltext=inlinecodefg,
  boxrule=0pt,
  arc=2pt,
  left=2pt,
  right=2pt,
  top=1pt,
  bottom=1pt
}
\renewcommand{\inlinecode}[1]{%
  \inlinecodebox{%
    \normalfont\mdseries\ttfamily\fontsize{9.9pt}{11pt}\selectfont #1%
  }%
}
\newsavebox{\pandocTableBox}
\newenvironment{tightblockquoteheading}{%
  \begin{mdframed}[
    rightline=false,
    bottomline=false,
    topline=false,
    linewidth=3pt,
    linecolor=blockquote-border,
    skipabove=0pt,
    skipbelow=0pt,
    innerleftmargin=7pt,
    innerrightmargin=0pt,
    innertopmargin=2.7pt,
    innerbottommargin=2.7pt
  ]%
  \begingroup
  \color{blockquote-text}
}{%
  \endgroup
  \end{mdframed}
}
]]

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

local function blocks_to_latex(blocks)
  return trim_text(pandoc.write(pandoc.Pandoc(blocks), "latex"))
end

local function caption_to_latex(inlines)
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

    local caption = caption_to_latex(image.caption)
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

local function adjust_blocks(blocks, list_depth)
  for i, block in ipairs(blocks) do
    if block.t == "OrderedList" then
      block = set_ordered_list_style(block, list_depth + 1)
      for j, item in ipairs(block.content) do
        block.content[j] = adjust_blocks(item, list_depth + 1)
      end
      blocks[i] = block
    elseif block.t == "BulletList" then
      for j, item in ipairs(block.content) do
        block.content[j] = adjust_blocks(item, list_depth + 1)
      end
      blocks[i] = block
    elseif block.t == "BlockQuote" or block.t == "Div" then
      block.content = adjust_blocks(block.content, list_depth)
      blocks[i] = block
    end
  end

  return blocks
end

function Pandoc(doc)
  if not FORMAT:match("latex") then
    return doc
  end

  doc.blocks = adjust_blocks(doc.blocks, 0)
  doc.blocks:insert(1, pandoc.RawBlock("latex", latex_preamble))
  return doc
end

-- Map of Unicode codepoints to LaTeX replacements.
-- Characters listed here will be substituted at the Pandoc AST level so that
-- LaTeX never sees the raw UTF-8 bytes (which would cause inputenc errors).
-- Characters NOT in this table but above U+007F are replaced with a safe
-- placeholder so that compilation always succeeds.
local unicode_to_latex = {
  -- Arrows
  [0x2190] = "\\(\\leftarrow\\)",
  [0x2191] = "\\(\\uparrow\\)",
  [0x2192] = "\\(\\rightarrow\\)",
  [0x2193] = "\\(\\downarrow\\)",
  [0x2194] = "\\(\\leftrightarrow\\)",
  [0x2195] = "\\(\\updownarrow\\)",
  [0x2196] = "\\(\\nwarrow\\)",
  [0x2197] = "\\(\\nearrow\\)",
  [0x2198] = "\\(\\searrow\\)",
  [0x2199] = "\\(\\swarrow\\)",
  [0x21D0] = "\\(\\Leftarrow\\)",
  [0x21D2] = "\\(\\Rightarrow\\)",
  [0x21D4] = "\\(\\Leftrightarrow\\)",
  [0x21A6] = "\\(\\mapsto\\)",
  -- Math operators and relations
  [0x00B1] = "\\(\\pm\\)",
  [0x00B7] = "\\(\\cdot\\)",
  [0x00D7] = "\\(\\times\\)",
  [0x00F7] = "\\(\\div\\)",
  [0x2200] = "\\(\\forall\\)",
  [0x2203] = "\\(\\exists\\)",
  [0x2205] = "\\(\\emptyset\\)",
  [0x2208] = "\\(\\in\\)",
  [0x2209] = "\\(\\notin\\)",
  [0x220B] = "\\(\\ni\\)",
  [0x2211] = "\\(\\sum\\)",
  [0x2212] = "\\(-\\)",
  [0x2213] = "\\(\\mp\\)",
  [0x2217] = "\\(\\ast\\)",
  [0x221A] = "\\(\\surd\\)",
  [0x221E] = "\\(\\infty\\)",
  [0x2220] = "\\(\\angle\\)",
  [0x2227] = "\\(\\land\\)",
  [0x2228] = "\\(\\lor\\)",
  [0x2229] = "\\(\\cap\\)",
  [0x222A] = "\\(\\cup\\)",
  [0x222B] = "\\(\\int\\)",
  [0x2234] = "\\(\\therefore\\)",
  [0x2235] = "\\(\\because\\)",
  [0x2248] = "\\(\\approx\\)",
  [0x2260] = "\\(\\neq\\)",
  [0x2261] = "\\(\\equiv\\)",
  [0x2264] = "\\(\\leq\\)",
  [0x2265] = "\\(\\geq\\)",
  [0x226A] = "\\(\\ll\\)",
  [0x226B] = "\\(\\gg\\)",
  [0x2282] = "\\(\\subset\\)",
  [0x2283] = "\\(\\supset\\)",
  [0x2286] = "\\(\\subseteq\\)",
  [0x2287] = "\\(\\supseteq\\)",
  [0x22A5] = "\\(\\perp\\)",
  [0x22C5] = "\\(\\cdot\\)",
  [0x2295] = "\\(\\oplus\\)",
  [0x2297] = "\\(\\otimes\\)",
  -- Greek letters
  [0x0391] = "A",
  [0x0392] = "B",
  [0x0393] = "\\(\\Gamma\\)",
  [0x0394] = "\\(\\Delta\\)",
  [0x0398] = "\\(\\Theta\\)",
  [0x039B] = "\\(\\Lambda\\)",
  [0x039E] = "\\(\\Xi\\)",
  [0x03A0] = "\\(\\Pi\\)",
  [0x03A3] = "\\(\\Sigma\\)",
  [0x03A6] = "\\(\\Phi\\)",
  [0x03A8] = "\\(\\Psi\\)",
  [0x03A9] = "\\(\\Omega\\)",
  [0x03B1] = "\\(\\alpha\\)",
  [0x03B2] = "\\(\\beta\\)",
  [0x03B3] = "\\(\\gamma\\)",
  [0x03B4] = "\\(\\delta\\)",
  [0x03B5] = "\\(\\varepsilon\\)",
  [0x03B6] = "\\(\\zeta\\)",
  [0x03B7] = "\\(\\eta\\)",
  [0x03B8] = "\\(\\theta\\)",
  [0x03B9] = "\\(\\iota\\)",
  [0x03BA] = "\\(\\kappa\\)",
  [0x03BB] = "\\(\\lambda\\)",
  [0x03BC] = "\\(\\mu\\)",
  [0x03BD] = "\\(\\nu\\)",
  [0x03BE] = "\\(\\xi\\)",
  [0x03C0] = "\\(\\pi\\)",
  [0x03C1] = "\\(\\rho\\)",
  [0x03C3] = "\\(\\sigma\\)",
  [0x03C4] = "\\(\\tau\\)",
  [0x03C5] = "\\(\\upsilon\\)",
  [0x03C6] = "\\(\\varphi\\)",
  [0x03C7] = "\\(\\chi\\)",
  [0x03C8] = "\\(\\psi\\)",
  [0x03C9] = "\\(\\omega\\)",
  -- Dashes, spaces, quotes
  [0x2013] = "--",
  [0x2014] = "---",
  [0x2018] = "`",
  [0x2019] = "'",
  [0x201C] = "``",
  [0x201D] = "''",
  [0x2026] = "\\ldots{}",
  [0x00A0] = "~",
  [0x2002] = "\\enspace{}",
  [0x2003] = "\\quad{}",
  -- Miscellaneous symbols
  [0x00A9] = "\\textcopyright{}",
  [0x00AE] = "\\textregistered{}",
  [0x2122] = "\\texttrademark{}",
  [0x00B0] = "\\textdegree{}",
  [0x00B2] = "\\textsuperscript{2}",
  [0x00B3] = "\\textsuperscript{3}",
  [0x00B9] = "\\textsuperscript{1}",
  [0x2022] = "\\textbullet{}",
  [0x2032] = "\\(\\prime\\)",
  [0x2033] = "\\(\\prime\\prime\\)",
  -- Currency
  [0x20AC] = "\\texteuro{}",
  [0x00A3] = "\\textsterling{}",
  [0x00A5] = "\\textyen{}",
  -- Check marks and crosses
  [0x2713] = "\\(\\checkmark\\)",
  [0x2714] = "\\(\\checkmark\\)",
  [0x2717] = "\\(\\times\\)",
  [0x2718] = "\\(\\times\\)",
  -- Ballot boxes (task list checkboxes)
  [0x2610] = "\\mdcheckbox{}",
  [0x2611] = "\\mdcheckboxchecked{}",
  [0x2612] = "\\mdcheckboxchecked{}",
  -- Geometric shapes
  [0x25A0] = "\\(\\blacksquare\\)",
  [0x25A1] = "\\(\\square\\)",
  [0x25CB] = "\\(\\circ\\)",
  [0x25CF] = "\\(\\bullet\\)",
  [0x25B2] = "\\(\\blacktriangle\\)",
  [0x25B6] = "\\(\\triangleright\\)",
  [0x25BC] = "\\(\\blacktriangledown\\)",
  [0x25C0] = "\\(\\triangleleft\\)",
  [0x2605] = "\\(\\bigstar\\)",
  -- Superscript digits
  [0x2070] = "\\textsuperscript{0}",
  [0x2074] = "\\textsuperscript{4}",
  [0x2075] = "\\textsuperscript{5}",
  [0x2076] = "\\textsuperscript{6}",
  [0x2077] = "\\textsuperscript{7}",
  [0x2078] = "\\textsuperscript{8}",
  [0x2079] = "\\textsuperscript{9}",
  -- Subscript digits
  [0x2080] = "\\textsubscript{0}",
  [0x2081] = "\\textsubscript{1}",
  [0x2082] = "\\textsubscript{2}",
  [0x2083] = "\\textsubscript{3}",
  [0x2084] = "\\textsubscript{4}",
  [0x2085] = "\\textsubscript{5}",
  [0x2086] = "\\textsubscript{6}",
  [0x2087] = "\\textsubscript{7}",
  [0x2088] = "\\textsubscript{8}",
  [0x2089] = "\\textsubscript{9}",
}

-- Characters in the Latin-1 supplement (U+00C0..U+00FF) are generally handled
-- by T1 fontenc + inputenc utf8, so we only need to worry about codepoints
-- above that range (plus a few specific ones already in the table above).
local function replace_unicode_for_latex(text)
  local out = {}
  local changed = false
  for _, codepoint in utf8.codes(text) do
    local replacement = unicode_to_latex[codepoint]
    if replacement then
      out[#out + 1] = replacement
      changed = true
    elseif codepoint > 0x024F then
      -- Beyond Latin Extended-B: not safe for inputenc, replace with placeholder
      out[#out + 1] = "?"
      changed = true
    else
      out[#out + 1] = utf8.char(codepoint)
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

local function has_class(el, class_name)
  for _, class in ipairs(el.classes) do
    if class == class_name then
      return true
    end
  end
  return false
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
  Str = Str,
  Math = Math,
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
