function! magit#state#is_file_visible(section, filename) dict
	return ( has_key(self.dict[a:section], a:filename) &&
		 \ ( self.dict[a:section][a:filename].visible == 1 ) )
endfunction

function! magit#state#is_dir(section, filename) dict
	return ( has_key(self.dict[a:section], a:filename) &&
		 \ ( self.dict[a:section][a:filename].dir != 0 ) )
endfunction

function! magit#state#get_files(mode) dict
	return self.dict[a:mode]
endfunction

" s:hunk_template: template for hunk object (nested in s:diff_template)
" WARNING: this variable must be deepcopy()'ied
let s:hunk_template = {
\	'header': '',
\	'lines': [],
\	'marks': [],
\}

" s:diff_template: template for diff object (nested in s:file_template)
" WARNING: this variable must be deepcopy()'ied
let s:diff_template = {
\	'header': [],
\	'hunks': [s:hunk_template],
\}

" s:file_template: template for file object
" WARNING: this variable must be deepcopy()'ied
let s:file_template = {
\	'exists': 0,
\	'status': '',
\	'empty': 0,
\	'dir': 0,
\	'binary': 0,
\	'symlink': '',
\	'diff': s:diff_template,
\}

" magit#state#get_file: function accessor for file
" param[in] mode: can be staged or unstaged
" param[in] filename: filename to access
" param[in] create: boolean. If 1, non existing file in Dict will be created.
" if 0, 'file_doesnt_exists' exception will be thrown
" return: Dict of file
function! magit#state#get_file(mode, filename, create) dict
	let file_exists = has_key(self.dict[a:mode], a:filename)
	if ( file_exists == 0 && a:create == 1 )
		let self.dict[a:mode][a:filename] = deepcopy(s:file_template)
		let self.dict[a:mode][a:filename].visible = 0
	elseif ( file_exists == 0 && a:create == 0 )
		throw 'file_doesnt_exists'
	endif
	return self.dict[a:mode][a:filename]
endfunction

" magit#state#get_header: function accessor for diff header
" param[in] mode: can be staged or unstaged
" param[in] filename: header of filename to access
" return: List of diff header lines
function! magit#state#get_header(mode, filename) dict
	let diff_dict_file = self.get_file(a:mode, a:filename, 0)
	return diff_dict_file.diff.header
endfunction

" magit#state#get_hunks: function accessor for hunks objects
" param[in] mode: can be staged or unstaged
" param[in] filename: hunks of filename to access
" return: List of List of hunks lines
function! magit#state#get_hunks(mode, filename) dict
	let diff_dict_file = self.get_file(a:mode, a:filename, 0)
	return diff_dict_file.diff.hunks
endfunction

" magit#state#get_hunks: function accessor for hunks lines
" param[in] mode: can be staged or unstaged
" param[in] filename: hunks of filename to access
" return: all hunks lines of a file, including hunk headers
function! magit#state#get_flat_hunks(mode, filename) dict
	let hunks = self.get_hunks(a:mode, a:filename)
	let lines = []
	for hunk in hunks
		call add(lines, hunk.header)
		call add(lines, hunk.lines)
	endfor
	return lines
endfunction

" magit#state#add_file: method to add a file with all its
" properties (filename, exists, status, header and hunks)
" param[in] mode: can be staged or unstaged
" param[in] status: one character status code of the file (AMDRCU?)
" param[in] filename: filename
function! magit#state#add_file(mode, status, filename, depth) dict
	let dev_null = ( a:status == '?' ) ? " /dev/null " : " "
	let staged_flag = ( a:mode == 'staged' ) ? " --staged " : " "
	let diff_cmd="git diff --no-ext-diff " . staged_flag .
				\ "--no-color --patch -- " . dev_null . " "
				\ .  magit#utils#add_quotes(a:filename)
	let diff_list=magit#utils#systemlist(diff_cmd)
	if ( empty(diff_list) )
		echoerr "diff command \"" . diff_cmd . "\" returned nothing"
	endif
	let diff_dict_file = self.get_file(a:mode, a:filename, 1)
	let diff_dict_file.exists = 1
	let diff_dict_file.status = a:status
	let diff_dict_file.depth = a:depth
	if ( a:status == '?' && getftype(a:filename) == 'link' )
		let diff_dict_file.symlink = resolve(a:filename)
		call add(diff_dict_file.diff.header, 'no header')
		let diff_dict_file.diff.hunks[0].header = 'New symbolic link file'
	elseif ( a:status == '?' && isdirectory(a:filename) == 1 )
		let diff_dict_file.dir = 1
		for subfile in split(globpath(a:filename, '\(.[^.]*\|*\)'), '\n')
			call self.add_file(a:mode, a:status, subfile, a:depth + 1)
		endfor
	elseif ( a:status == '?' && getfsize(a:filename) == 0 )
		let diff_dict_file.empty = 1
		call add(diff_dict_file.diff.header, 'no header')
		let diff_dict_file.diff.hunks[0].header = 'New empty file'
	elseif ( match(system("file --mime " .
				\ magit#utils#add_quotes(a:filename)),
				\ a:filename . ".*charset=binary") != -1 )
		let diff_dict_file.binary = 1
		call add(diff_dict_file.diff.header, 'no header')
		let diff_dict_file.diff.hunks[0].header = 'Binary file'
	else
		let line = 0
		" match(
		while ( line < len(diff_list) && diff_list[line] !~ "^@.*" )
			call add(diff_dict_file.diff.header, diff_list[line])
			let line += 1
		endwhile

		let hunk = diff_dict_file.diff.hunks[0]
		let hunk.header = diff_list[line]

		for diff_line in diff_list[line+1 : -1]
			if ( diff_line =~ "^@.*" )
				let hunk = deepcopy(s:hunk_template)
				call add(diff_dict_file.diff.hunks, hunk)
				let hunk.header = diff_line
				continue
			endif
			call add(hunk.lines, diff_line)
		endfor
	endif
endfunction

" magit#state#update: update self.dict
" if a file does not exists anymore (because all its changes have been
" committed, deleted, discarded), it is removed from g:mg_diff_dict
" else, its diff is discarded and regenrated
" what is resilient is its 'visible' parameter
function! magit#state#update() dict
	for diff_dict_mode in values(self.dict)
		for file in values(diff_dict_mode)
			let file.exists = 0
			" always discard previous diff
			let file.diff = deepcopy(s:diff_template)
		endfor
	endfor

	let dir = getcwd()
	try
		call magit#utils#lcd(magit#utils#top_dir())
		for [mode, diff_dict_mode] in items(self.dict)
			let status_list = magit#git#get_status()
			for file_status in status_list
				let status=file_status[mode]

				" untracked code apperas in staged column, we skip it
				if ( status == ' ' || ( ( mode == 'staged' ) && status == '?' ) )
					continue
				endif
				call self.add_file(mode, status, file_status.filename, 0)
			endfor
		endfor
	finally
		call magit#utils#lcd(dir)
	endtry

	" remove files that have changed their mode or been committed/deleted/discarded...
	for diff_dict_mode in values(self.dict)
		for [key, file] in items(diff_dict_mode)
			if ( file.exists == 0 )
				unlet diff_dict_mode[key]
			endif
		endfor
	endfor
endfunction

" dict: structure containing all diffs
" It is formatted as follow
" {
"   'staged': {
"       'filename': s:file_template,
"       'filename': s:file_template,
"       ...
"   },
"   'unstaged': {
"       'filename': s:file_template,
"       'filename': s:file_template,
"       ...
"   },
" }
let magit#state#state = {
			\ 'get_file': function("magit#state#get_file"),
			\ 'get_files': function("magit#state#get_files"),
			\ 'get_header': function("magit#state#get_header"),
			\ 'get_hunks': function("magit#state#get_hunks"),
			\ 'get_flat_hunks': function("magit#state#get_flat_hunks"),
			\ 'add_file': function("magit#state#add_file"),
			\ 'is_dir': function("magit#state#is_dir"),
			\ 'is_file_visible': function("magit#state#is_file_visible"),
			\ 'update': function("magit#state#update"),
			\ 'dict': { 'staged': {}, 'unstaged': {}},
			\ }

