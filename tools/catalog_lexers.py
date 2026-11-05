# Small lexers for dialects absent from Pygments' bundled lexer catalogue.
# These color lexical categories; they do not claim to validate the programs.
import re
from pygments.lexer import RegexLexer, bygroups, using, include
from pygments.lexers import PerlLexer, QBasicLexer
from pygments.token import Comment, Keyword, Name, Number, String, Text, Operator, Punctuation


# Recognize Oberon-2 modules, native nested comments, and LONGREAL literals.
# Inputs: source text. Outputs: Pygments token stream. Used by render_sources.
class OberonLexer(RegexLexer):
    name = 'Oberon-2 (project lexer)'
    tokens = {
        'root': [
            (r'\(\*', Comment.Multiline, 'comment'),
            (r'"[^"\n]*"', String),
            (r'\b[0-9][0-9A-F]*X\b', Number.Hex),
            (r'\b\d+(?:\.\d*)?(?:[DE][+-]?\d+)?', Number),
            (r'\b(?:MODULE|IMPORT|CONST|TYPE|VAR|POINTER|TO|RECORD|ARRAY|OF|PROCEDURE|IS|BEGIN|END|IF|THEN|ELSE|ELSIF|WHILE|DO|FOR|BY|LOOP|EXIT|RETURN|OR|DIV|MOD|NIL|TRUE|FALSE)\b', Keyword),
            (r'\b(?:INTEGER|LONGINT|REAL|LONGREAL|BOOLEAN|CHAR|SET|SYSTEM|NEW|INC|DEC|HALT|LEN|SIZE|ORD)\b', Keyword.Type),
            (r'[A-Za-z_][\w]*', Name),
            (r'[:=+*/#&<>-]+', Operator), (r'[.;,()\[\]]', Punctuation), (r'\s+', Text),
        ],
        'comment': [(r'\(\*', Comment.Multiline, '#push'), (r'\*\)', Comment.Multiline, '#pop'), (r'[^(*]+|.', Comment.Multiline)],
    }


# Highlight fully free RPG together with its embedded SQL keywords.
# Inputs: SQLRPGLE text. Outputs: tokens. Used by render_sources for the IBM i page.
class RpgLexer(RegexLexer):
    name = 'Fully free RPG / embedded SQL (project lexer)'
    flags = re.MULTILINE | re.IGNORECASE
    tokens = {'root': [
        (r'^\*\*free', Comment.Preproc), (r'//[^\n]*', Comment.Single),
        (r"(?:x)?'(?:''|[^'])*'", String),
        (r'%[a-z][\w]*', Name.Builtin), (r'\*[a-z][\w]*', Keyword.Constant),
        (r'\b(?:dcl-(?:s|c|pr|pi|proc)|end-(?:pr|pi|proc)|ctl-opt|monitor|on-error|endmon|if|else|elseif|endif|dow|dou|enddo|for|endfor|leave|return|dsply|clear|and|or|not|exec|sql|select|into|from|where|values|case|when|then|end|declare|cursor|fetch|open|close|insert|update|delete|set|call|order|by|between|as)\b', Keyword),
        (r'\b(?:char|varchar|int|uns|packed|float|ind|pointer|const|value|dim|based|inz|extproc|extpgm|options)\b', Keyword.Type),
        (r'\b\d+(?:\.\d*)?', Number), (r'[a-z_][\w]*', Name),
        (r'[:=+*/<>-]+', Operator), (r'[.;,()]', Punctuation), (r'\s+', Text),
    ]}


# Color the real Latin program while delegating its marked prelude to PerlLexer.
# Inputs: complete hybrid source. Outputs: tokens. Used by the Perligata page.
class PerligataLexer(RegexLexer):
    name = 'Perligata + explicit Perl bridge (project lexer)'
    tokens = {
        'root': [(r'(?s)(.*?)(use Lingua::Romana::Perligata;)',
                  bygroups(using(PerlLexer), Keyword.Namespace), 'latin')],
        'latin': [
            (r'(?ms)^ecce explico\n.*?^ecce seco\s*$', Comment.Multiline),
            (r'\badnota[^\n]*', Comment.Single),
            (r'dictum\s+sic\s+.*?\s+cis', String),
            (r'\b(?:sic|cis|si|nisi|dum|donec|fac|per|quisque|in|posterus|ultimus|redde|meo|meis|ad|da|tum|cum|atque|vel|non)\b', Keyword),
            (r'\b(?:[IVXLCDM]+|nullum|unum|duo|tres|secundum)\b|\(\(I\)\)I\)\)', Number),
            (r'\b\w+ere\b', Name.Function),
            (r'\b\w+(?:mentum|menta|mento)\b', Name.Builtin),
            (r'\b\w+(?:um|is|orum|o)\b', Name.Variable),
            (r'[\w]+', Name), (r'[.()]', Punctuation), (r'\s+', Text),
        ],
    }


# Extend the BASIC lexer for FreeBASIC's native block comments.
# Inputs: FreeBASIC source. Outputs: tokens. Used by its highlighted HTML page.
class FreeBasicLexer(QBasicLexer):
    name = 'FreeBASIC (QBasic lexer with block comments)'
    tokens = {'root': [(r"(?s)/'.*?'/", Comment.Multiline), include('qbasic')],
              'qbasic': QBasicLexer.tokens['root']}
