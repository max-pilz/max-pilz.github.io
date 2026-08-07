--[[
multiple-bibliographies – create multiple bibliographies

Fixed for Pandoc 3.x compatibility.
Supports both naming conventions:
  - "bibliography_xxx" / "#refs_xxx" (underscore, original)
  - "xxx-bibliography" / "#refs-xxx" (hyphen, common usage)

Based on the original by Albert Krewinkel (2018-2021), ISC License.
]]

local List = require 'pandoc.List'
local utils = require 'pandoc.utils'

--- Collection of all cites in the document
local all_cites = {}
--- Document meta value
local doc_meta = pandoc.Meta{}

--- Div used by citeproc to insert the bibliography.
local refs_div = pandoc.Div({}, pandoc.Attr('refs'))

-- Div filled by citeproc with properties set according to
-- the output format and the attributes of cs:bibliography
local refs_div_with_properties

--- Run citeproc on a document (compatible with Pandoc 2.19.1+)
local function run_citeproc(doc)
  if PANDOC_VERSION >= "2.19.1" then
    -- Use built-in citeproc (no external process needed)
    return utils.citeproc(doc)
  elseif PANDOC_VERSION >= "2.11" then
    return utils.run_json_filter(
      doc,
      'pandoc',
      {'--from=json', '--to=json', '--citeproc', '--quiet'}
    )
  else
    return utils.run_json_filter(
      doc,
      'pandoc-citeproc',
      {FORMAT, '-q'}
    )
  end
end

--- Get all bibliography fields from metadata.
--- Supports both "bibliography_xxx" and "xxx-bibliography" naming.
local function get_bibliography_mapping(meta)
  local mapping = {}
  for name, value in pairs(meta) do
    -- Match "bibliography_xxx" or "bibliography-xxx"
    local suffix = name:match('^bibliography[_-](.+)$')
    if suffix then
      mapping[suffix] = value
    end
    -- Match "xxx-bibliography" or "xxx_bibliography"
    local prefix = name:match('^(.+)[_-]bibliography$')
    if prefix then
      mapping[prefix] = value
    end
  end
  return mapping
end

--- Resolve citations in the document by combining all bibliographies
-- before running citeproc on the full document.
local function resolve_doc_citations(doc)
  local meta = doc.meta
  local orig_bib = meta.bibliography
  local bib_mapping = get_bibliography_mapping(meta)

  -- Combine all bibliographies into one list
  local all_bibs = pandoc.MetaList{}
  if orig_bib then
    if orig_bib.t == 'MetaList' then
      for _, b in ipairs(orig_bib) do
        table.insert(all_bibs, b)
      end
    else
      table.insert(all_bibs, orig_bib)
    end
  end
  for _, value in pairs(bib_mapping) do
    table.insert(all_bibs, value)
  end
  meta.bibliography = all_bibs

  -- Add dummy div to catch the created bibliography
  table.insert(doc.blocks, refs_div)

  -- Resolve all citations
  doc = run_citeproc(doc)

  -- Remove catch-all bibliography and keep it for future use
  refs_div_with_properties = table.remove(doc.blocks)

  -- Restore bibliography to original value
  doc.meta.bibliography = orig_bib
  return doc
end

--- Explicitly create a new meta object with all fields relevant for citeproc.
local function meta_for_citeproc(bibliography)
  local fields = {
    'bibliography', 'references', 'csl', 'citation-style',
    'link-citations', 'citation-abbreviations', 'lang',
    'suppress-bibliography', 'reference-section-title',
    'notes-after-punctuation', 'nocite'
  }
  local new_meta = pandoc.Meta{}
  for _, field in ipairs(fields) do
    new_meta[field] = doc_meta[field]
  end
  new_meta.bibliography = bibliography
  return new_meta
end

local function remove_duplicates(classes)
  local seen = {}
  return classes:filter(function(x)
    if seen[x] then
      return false
    else
      seen[x] = true
      return true
    end
  end)
end

--- Create a bibliography for a given topic.
local function create_topic_bibliography(div)
  -- Match div IDs: "refs-xxx" or "refs_xxx"
  local name = div.identifier:match('^refs[_-](.+)$')
  if not name then
    return nil
  end

  local bib_mapping = get_bibliography_mapping(doc_meta)
  local bibfile = bib_mapping[name]
  if not bibfile then
    return nil
  end

  -- Build a temporary document with all cites and run citeproc
  local tmp_blocks = {}
  if #all_cites > 0 then
    tmp_blocks[#tmp_blocks + 1] = pandoc.Para(all_cites)
  else
    -- Need at least one block for a valid document
    tmp_blocks[#tmp_blocks + 1] = pandoc.Para{pandoc.Str(" ")}
  end
  tmp_blocks[#tmp_blocks + 1] = pandoc.Div({}, pandoc.Attr('refs'))

  local tmp_meta = meta_for_citeproc(bibfile)
  local tmp_doc = pandoc.Pandoc(tmp_blocks, tmp_meta)
  local res = run_citeproc(tmp_doc)

  -- Find the refs div in the result
  local refs_block = nil
  for _, block in ipairs(res.blocks) do
    if block.t == 'Div' and block.identifier == 'refs' then
      refs_block = block
      break
    end
  end

  if refs_block and #refs_block.content > 0 then
    div.content = refs_block.content
    if refs_div_with_properties then
      div.classes = remove_duplicates(refs_div_with_properties.classes)
      div.attributes = refs_div_with_properties.attributes
    end
  end

  return div
end

return {
  {
    Cite = function(c) all_cites[#all_cites + 1] = c end,
    Meta = function(m) doc_meta = m end,
  },
  { Pandoc = resolve_doc_citations },
  { Div = create_topic_bibliography },
}