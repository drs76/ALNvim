" AL (Business Central / Dynamics 365) syntax file
" Derived from the official AL TextMate grammar (alsyntax.tmlanguage)
if exists("b:current_syntax")
  finish
endif

syntax case ignore

" ── Comments ──────────────────────────────────────────────────────────────────
syntax region  alComment      start="//"  end="$"   keepend
syntax region  alComment      start="/\*" end="\*/"
" Preprocessor directives (#region, #if, #define …)
syntax match   alPreproc      "^\s*#\w.*$"

" ── Strings ───────────────────────────────────────────────────────────────────
syntax region  alString       start="'"  end="'"  skip="''"  oneline  contains=alStringEscape
syntax match   alStringEscape "''"                                      contained
syntax region  alVerbatim     start="@'" end="'"  skip="''"  oneline
" Quoted identifiers  e.g.  "My Field"
syntax region  alQuotedIdent  start='"'  end='"'  oneline

" ── Numbers ───────────────────────────────────────────────────────────────────
syntax match   alNumber       "\b\(\(0[xX][0-9a-fA-F]*\)\|\(\([0-9]\+\.\?[0-9]*\)\|\(\.[0-9]\+\)\)\([eE][+-]\?[0-9]\+\)\?\)[LlUuFf]*\b"

" ── Control-flow keywords ─────────────────────────────────────────────────────
syntax keyword alConditional  if then else case of
syntax keyword alRepeat       for foreach while repeat until do downto to
syntax keyword alStatement    begin end exit break continue

" ── Declaration keywords ──────────────────────────────────────────────────────
syntax keyword alDeclaration  var procedure trigger local internal protected public
syntax keyword alModifier     abstract virtual override sealed runonclient suppressdispose
syntax keyword alModifier     indataset temporary withevents securityfiltering

" ── Control keywords (misc) ───────────────────────────────────────────────────
syntax keyword alKeyword      array asserterror event function program with
syntax keyword alException    error

" ── Operators (word-form) ────────────────────────────────────────────────────
syntax keyword alOperator     and or not xor div mod is as

" ── Object-type keywords ──────────────────────────────────────────────────────
syntax keyword alObject       table tableextension page pageextension pagecustomization
syntax keyword alObject       codeunit report reportextension query xmlport
syntax keyword alObject       enum enumextension interface permissionset permissionsetextension
syntax keyword alObject       profile profileextension controladdin entitlement dotnet value

" ── Metadata / structure keywords ────────────────────────────────────────────
syntax keyword alMetadata     add addfirst addlast addafter addbefore
syntax keyword alMetadata     action actions area assembly chartpart cuegroup
syntax keyword alMetadata     column customizes dataitem dataset elements extends
syntax keyword alMetadata     field fieldattribute fieldelement fieldgroup fieldgroups
syntax keyword alMetadata     fields filter fixed grid group implements
syntax keyword alMetadata     key keys label labels layout modify
syntax keyword alMetadata     movefirst movelast movebefore moveafter
syntax keyword alMetadata     namespace part rendering repeater usercontrol
syntax keyword alMetadata     requestpage schema separator systempart
syntax keyword alMetadata     tableelement textattribute textelement type using

" ── Property-value keywords ───────────────────────────────────────────────────
syntax keyword alProperty     average const count exist field filter lookup
syntax keyword alProperty     max min order sorting sum tabledata upperlimit
syntax keyword alProperty     where ascending descending

" ── Built-in types ────────────────────────────────────────────────────────────
syntax keyword alType         action actionref array auditcategory automation
syntax keyword alType         biginteger bigtext secrettext blob boolean byte
syntax keyword alType         char clienttype code codeunit completiontriggererrorlevel
syntax keyword alType         connectiontype customaction database dataclassification
syntax keyword alType         datascope datatransfer date dateformula datetime decimal
syntax keyword alType         defaultlayout dialog dictionary dotnet dotnetassembly
syntax keyword alType         dotnettypedeclaration duration enum errorinfo errortype
syntax keyword alType         executioncontext executionmode fieldclass fieldref
syntax keyword alType         fieldtype file fileupload fileuploadaction
syntax keyword alType         filterpagebuilder guid instream integer interface
syntax keyword alType         isolationlevel joker keyref label list media mediaset
syntax keyword alType         moduledependencyinfo moduleinfo none notification
syntax keyword alType         notificationscope objecttype option outstream page
syntax keyword alType         pagebackgroundtaskerrorlevel pageresult pagestyle
syntax keyword alType         query record recordid recordref report reportformat
syntax keyword alType         securityfilter securityfiltering securityoperationresult
syntax keyword alType         sessionsettings systemaction table tableconnectiontype
syntax keyword alType         tablefilter testaction testfield testfilterfield
syntax keyword alType         testhttprequestmessage testhttpresponsemessage
syntax keyword alType         testpage testpermissions testrequestpage text
syntax keyword alType         textbuilder textconst textencoding time
syntax keyword alType         transactionmodel transactiontype variant verbosity
syntax keyword alType         version xmlport
syntax keyword alType         httpcontent httpheaders httpclient
syntax keyword alType         httprequestmessage httpresponsemessage httprequesttype cookie
syntax keyword alType         jsontoken jsonvalue jsonarray jsonobject
syntax keyword alType         view views
syntax keyword alType         xmlattribute xmlattributecollection xmlcomment xmlcdata
syntax keyword alType         xmldeclaration xmldocument xmldocumenttype xmlelement
syntax keyword alType         xmlnamespacemanager xmlnametable xmlnode xmlnodelist
syntax keyword alType         xmlprocessinginstruction xmlreadoptions xmltext xmlwriteoptions
syntax keyword alType         webserviceactioncontext webserviceactionresultcode

" ── Boolean constants ─────────────────────────────────────────────────────────
syntax keyword alBoolean      true false

" ── Attributes  [ObsoleteState(...)] etc. ────────────────────────────────────
syntax region  alAttribute    start="\[" end="\]" contains=alString,alNumber

" ── Punctuation ───────────────────────────────────────────────────────────────
syntax match   alPunctuation  "[;:,]"

" ── Highlight links ───────────────────────────────────────────────────────────
highlight default link alComment      Comment
highlight default link alPreproc      PreProc
highlight default link alString       String
highlight default link alStringEscape SpecialChar
highlight default link alVerbatim     String
highlight default link alQuotedIdent  Identifier
highlight default link alNumber       Number
highlight default link alConditional  Conditional
highlight default link alRepeat       Repeat
highlight default link alStatement    Statement
highlight default link alDeclaration  Keyword
highlight default link alModifier     StorageClass
highlight default link alKeyword      Keyword
highlight default link alException    Exception
highlight default link alOperator     Operator
highlight default link alObject       Structure
highlight default link alMetadata     Keyword
highlight default link alProperty     Identifier
highlight default link alType         Type
highlight default link alBoolean      Boolean
highlight default link alAttribute    PreProc
highlight default link alPunctuation  Delimiter

let b:current_syntax = "al"
