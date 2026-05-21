# frozen_string_literal: true

require 'digest'
require 'parser/current'

# The generated protobuf classes — these come from
# scripts/gen-proto.sh (a follow-up). We reference them as
# constants lazily so the file loads cleanly even before
# the stubs exist.

module RubyWorker
  # Parser walks each requested Ruby file via the
  # whitequark/parser gem and produces the ParsedFile
  # messages the Go-side structural detectors consume.
  #
  # Mirrors `workers/ts/src/parser.ts` and
  # `workers/php/src/Parser.php` structurally — same six
  # collectors, same hashing scheme, same block-extraction
  # shape. Cross-language symmetry isn't accidental; it's how
  # the canonical-hash detector clusters Ruby / TS / Go /
  # PHP functions that share a structural shape.
  #
  # ## Hashing scheme
  #
  # Two hashes per function:
  #
  #   * `hash` (language-specific): captures Ruby-flavored AST
  #     node types including operator method names on `:send`
  #     nodes. Two Ruby methods with the same hash share AST
  #     shape modulo identifier names and literal values.
  #   * `canonical_hash` (cross-language): same scheme using
  #     the universal token vocabulary defined in
  #     core/pkg/structural/lang/canonical.go.
  #
  # Both hashes use SHA-1 truncated to 16 hex chars. Trivial
  # bodies (≤2 nodes) short-circuit to "".
  #
  # ## Concerns
  #
  # Per-file concerns are categorized into ConcernEvidenceRef
  # entries tagged with one of the eight canonical
  # categories. The classifier looks at:
  #
  #   * `:send` nodes whose method is a known state / network
  #     / io / config / dataaccess identifier
  #   * `[]` accesses on session / cookies / ENV
  #   * Rails.cache, Rails.application.config
  #   * High-complexity methods → business
  #
  # The taxonomy aligns with the Rails framework profile in
  # `core/pkg/structural/framework/rails.go`.
  #
  # ## Error tolerance
  #
  # Syntactically broken Ruby still yields a partial
  # ParsedFile with whatever the parser salvaged. The
  # `parse_error` field carries the SyntaxError's message
  # verbatim. The parser gem itself has best-in-class error
  # recovery (it's what RuboCop relies on for partial parses).
  class Parser
    BUSINESS_COMPLEXITY = 8
    MIN_BLOCK_STMTS = 3
    HASH_HEX_LEN = 16

    def initialize
      @ruby_parser = ::Parser::CurrentRuby.new
      # Silence parser-gem warnings on stderr — they pollute
      # the gRPC server logs.
      @ruby_parser.diagnostics.all_errors_are_fatal = false
      @ruby_parser.diagnostics.ignore_warnings = true
    end

    # @param repo_path [String] absolute repo root path
    # @param rel_paths [Array<String>] repo-relative file paths
    # @return [Array<Object>] ParsedFile proto messages
    def parse_files(repo_path, rel_paths)
      rel_paths.map { |rel| parse_one(repo_path, rel) }
    end

    private

    def parsed_file_class
      @parsed_file_class ||= ::Revund::Worker::V1::ParsedFile
    end

    def parse_one(repo_path, rel)
      abs = File.join(repo_path, rel)
      pf = parsed_file_class.new(path: rel, language: 'ruby')

      unless File.readable?(abs)
        pf.parse_error = "file not readable: #{abs}"
        return pf
      end

      source = File.read(abs)
      buffer = ::Parser::Source::Buffer.new(abs)
      buffer.source = source

      @ruby_parser.reset
      ast = nil
      begin
        ast = @ruby_parser.parse(buffer)
      rescue ::Parser::SyntaxError => e
        pf.parse_error = e.message
        return pf
      end

      # whitequark/parser returns nil for empty / whitespace-
      # only files. Not an error — return the empty ParsedFile.
      return pf if ast.nil?

      pf.imports = collect_imports(ast)
      pf.decls = collect_decls(ast)
      pf.functions = collect_functions(ast)
      pf.concerns = collect_concerns(ast)
      pf
    end

    # ────────────────────────────────────────────────
    # Imports: require / require_relative / autoload
    # ────────────────────────────────────────────────

    def import_ref_class
      @import_ref_class ||= ::Revund::Worker::V1::ImportRef
    end

    def collect_imports(ast)
      out = []
      walk(ast) do |node|
        next unless node.is_a?(::Parser::AST::Node) && node.type == :send
        receiver, method, *args = node.children
        next unless receiver.nil? # bare top-level calls only

        case method
        when :require, :require_relative
          path_node = args.first
          next unless path_node && path_node.type == :str
          out << import_ref_class.new(
            path: path_node.children.first.to_s,
            alias: '',
            line: node.loc.line,
          )
        when :autoload
          # autoload(:Const, "path/to/file")
          const_node, path_node = args
          next unless const_node && path_node && path_node.type == :str
          alias_name = const_node.type == :sym ? const_node.children.first.to_s : ''
          out << import_ref_class.new(
            path: path_node.children.first.to_s,
            alias: alias_name,
            line: node.loc.line,
          )
        end
      end
      out
    end

    # ────────────────────────────────────────────────
    # Decls: class / module / def / casgn (constants)
    # ────────────────────────────────────────────────

    def decl_ref_class
      @decl_ref_class ||= ::Revund::Worker::V1::DeclRef
    end

    def collect_decls(ast)
      out = []
      # Top-level only. A top-level :begin wraps a list of
      # statements; unwrap it. Nested class methods produce
      # FunctionRef entries via collect_functions, not decls.
      top_nodes = ast.type == :begin ? ast.children : [ast]
      top_nodes.each do |node|
        next unless node.is_a?(::Parser::AST::Node)
        decl = decl_from_node(node)
        out << decl if decl
      end
      out
    end

    def decl_from_node(node)
      case node.type
      when :class
        name = const_name(node.children[0])
        return nil if name.empty?
        decl_ref_class.new(
          name: name,
          kind: 'class',
          line: node.loc.line,
          end_line: end_line_of(node),
          exported: true,
        )
      when :module
        name = const_name(node.children[0])
        return nil if name.empty?
        decl_ref_class.new(
          name: name,
          kind: 'module',
          line: node.loc.line,
          end_line: end_line_of(node),
          exported: true,
        )
      when :def
        decl_ref_class.new(
          name: node.children[0].to_s,
          kind: 'method',
          line: node.loc.line,
          end_line: end_line_of(node),
          exported: true,
        )
      when :casgn
        name_node = node.children[1]
        decl_ref_class.new(
          name: name_node.to_s,
          kind: 'constant',
          line: node.loc.line,
          end_line: end_line_of(node),
          exported: true,
        )
      end
    end

    def const_name(node)
      return '' unless node.is_a?(::Parser::AST::Node)
      return node.children[1].to_s if node.type == :const
      ''
    end

    def end_line_of(node)
      loc = node.loc
      return loc.line unless loc.respond_to?(:expression) && loc.expression
      loc.expression.last_line
    end

    # ────────────────────────────────────────────────
    # Functions: every :def / :defs anywhere in the file
    # ────────────────────────────────────────────────

    def function_ref_class
      @function_ref_class ||= ::Revund::Worker::V1::FunctionRef
    end

    def collect_functions(ast)
      out = []
      walk(ast) do |node|
        next unless node.is_a?(::Parser::AST::Node)
        case node.type
        when :def
          out << build_function_ref(node.children[0].to_s, node, is_method: true, is_exported: true)
        when :defs
          # `def self.foo` — singleton method.
          out << build_function_ref(node.children[1].to_s, node, is_method: true, is_exported: true)
        end
      end
      out
    end

    def build_function_ref(name, node, is_method:, is_exported:)
      function_ref_class.new(
        name: name,
        start_line: node.loc.line,
        end_line: end_line_of(node),
        complexity: cyclomatic_complexity(node),
        is_method: is_method,
        is_exported: is_exported,
        hash: hash_function_body(node),
        canonical_hash: canonical_hash_body(node),
        blocks: extract_blocks(node),
      )
    end

    # Cyclomatic complexity (McCabe): start at 1, add 1 per
    # decision point.
    #
    # Decision points in Ruby:
    #   - :if (the else arm doesn't add — it's the negation)
    #   - :while, :until, :for
    #   - :when (each case arm)
    #   - :resbody (each rescue clause)
    #
    # We don't count short-circuit && / || or the ternary
    # to match the Go + TS + PHP counterparts.
    def cyclomatic_complexity(node)
      score = 1
      walk(node) do |n|
        next unless n.is_a?(::Parser::AST::Node)
        case n.type
        when :if, :while, :until, :for
          score += 1
        when :when, :resbody
          score += 1
        end
      end
      score
    end

    # ────────────────────────────────────────────────
    # Hashing
    # ────────────────────────────────────────────────

    def hash_function_body(node)
      body = function_body(node)
      tokens = []
      nodes = walk_for_hash(body, tokens, canonical: false)
      return '' if nodes <= 2
      Digest::SHA1.hexdigest(tokens.join(';'))[0, HASH_HEX_LEN]
    end

    def canonical_hash_body(node)
      body = function_body(node)
      tokens = []
      nodes = walk_for_hash(body, tokens, canonical: true)
      return '' if nodes <= 2
      Digest::SHA1.hexdigest(tokens.join(';'))[0, HASH_HEX_LEN]
    end

    # Returns the function body node.
    #   :def  → (name, args, body) — body is children[2]
    #   :defs → (receiver, name, args, body) — body is children[3]
    def function_body(node)
      case node.type
      when :def then node.children[2]
      when :defs then node.children[3]
      else node
      end
    end

    # Walks a node (or array of nodes) producing the hash
    # token stream. Returns the total node count so the
    # caller can short-circuit trivial bodies.
    def walk_for_hash(node, tokens, canonical:)
      count = 0
      stack = node.is_a?(Array) ? node.dup : [node]
      until stack.empty?
        n = stack.shift
        next if n.nil?
        next unless n.is_a?(::Parser::AST::Node)

        count += 1
        tokens << (canonical ? canonical_token(n) : ruby_token(n))

        # Identifiers / literals carry no children worth
        # descending into for hashing.
        case n.type
        when :lvar, :ivar, :cvar, :gvar, :arg, :const, :sym, :str, :int, :float, :true, :false, :nil
          next
        end

        n.children.each do |child|
          stack.push(child) if child.is_a?(::Parser::AST::Node)
        end
      end
      count
    end

    def ruby_token(node)
      case node.type
      when :lvar, :ivar, :cvar, :gvar, :arg, :const
        'I'
      when :str
        'L:STR'
      when :int, :float
        'L:NUM'
      when :true, :false
        'L:BOOL'
      when :nil
        'L:NIL'
      when :sym
        'L:SYM'
      when :send
        method = node.children[1]
        method ? "SEND:#{method}" : node.type.to_s
      else
        node.type.to_s
      end
    end

    # Canonical token vocabulary — mirrors
    # core/pkg/structural/lang/canonical.go.
    def canonical_token(node)
      case node.type
      when :if
        'IF'
      when :while, :until, :for
        'FOR'
      when :return
        'RETURN'
      when :lvasgn, :ivasgn, :cvasgn, :gvasgn, :casgn, :masgn, :op_asgn
        'ASSIGN'
      when :case
        'SWITCH'
      when :when
        'IF' # case arms are conditional branches at the canonical level
      when :break
        'BREAK'
      when :next
        'CONTINUE'
      when :begin
        # :begin can be a statement list OR a try/rescue
        # construct; distinguish via presence of :rescue
        # children.
        has_rescue = node.children.any? { |c| c.is_a?(::Parser::AST::Node) && c.type == :rescue }
        has_rescue ? 'TRY' : 'BLOCK'
      when :rescue, :resbody
        'TRY'
      when :ensure
        'DEFER'
      when :send, :csend
        # Ruby binary operators are method calls under the
        # hood (`1 + 2` is `1.+(2)`). Distinguish them by
        # method name so `+` and `-` hash differently.
        method = node.children[1].to_s
        case method
        when '+', '-', '*', '/', '%', '**', '<<', '>>', '&', '|', '^',
             '==', '!=', '===', '<', '<=', '>', '>=', '=~', '<=>'
          "BIN:#{method}"
        when '!', '-@', '+@', '~'
          "UN:#{method}"
        else
          'CALL'
        end
      when :block
        'CALL' # `foo { ... }` is a call with a block
      when :and, :or
        node.type == :and ? 'BIN:&&' : 'BIN:||'
      when :not
        'UN:!'
      when :index
        'INDEX'
      when :const, :lvar, :ivar, :cvar, :gvar, :arg
        'ID'
      when :str
        'LIT:STR'
      when :int, :float
        'LIT:NUM'
      when :true, :false
        'LIT:BOOL'
      when :nil
        'LIT:NIL'
      when :sym
        'LIT:SYM'
      when :class, :module, :def, :defs, :sclass
        'NODE'
      else
        'NODE'
      end
    end

    # ────────────────────────────────────────────────
    # Block extraction
    # ────────────────────────────────────────────────

    def block_ref_class
      @block_ref_class ||= ::Revund::Worker::V1::BlockRef
    end

    def extract_blocks(fn_node)
      out = []
      body = function_body(fn_node)
      return out if body.nil?

      walk(body) do |node|
        next unless node.is_a?(::Parser::AST::Node)
        case node.type
        when :if
          then_body = node.children[1]
          else_body = node.children[2]
          add_block(out, then_body, 'if') if then_body
          add_block(out, else_body, 'else') if else_body
        when :while, :until
          body_node = node.children[1]
          add_block(out, body_node, 'for') if body_node
        when :for
          body_node = node.children[2]
          add_block(out, body_node, 'for') if body_node
        when :when
          body_node = node.children.last
          add_block(out, body_node, 'case') if body_node
        when :resbody
          body_node = node.children[2]
          add_block(out, body_node, 'rescue') if body_node
        end
      end
      out
    end

    def add_block(out, body_node, kind)
      stmts = body_statements(body_node)
      return if stmts.size < MIN_BLOCK_STMTS

      hash = hash_node(body_node)
      canon = canonical_hash_node(body_node)
      return if hash.empty? && canon.empty?

      out << block_ref_class.new(
        kind: kind,
        start_line: body_node.loc.line,
        end_line: end_line_of(body_node),
        hash: hash,
        canonical_hash: canon,
      )
    end

    def body_statements(body_node)
      return [] unless body_node.is_a?(::Parser::AST::Node)
      return body_node.children if body_node.type == :begin
      [body_node]
    end

    def hash_node(node)
      tokens = []
      nodes = walk_for_hash(node, tokens, canonical: false)
      return '' if nodes <= 2
      Digest::SHA1.hexdigest(tokens.join(';'))[0, HASH_HEX_LEN]
    end

    def canonical_hash_node(node)
      tokens = []
      nodes = walk_for_hash(node, tokens, canonical: true)
      return '' if nodes <= 2
      Digest::SHA1.hexdigest(tokens.join(';'))[0, HASH_HEX_LEN]
    end

    # ────────────────────────────────────────────────
    # Concerns
    # ────────────────────────────────────────────────

    def concern_ref_class
      @concern_ref_class ||= ::Revund::Worker::V1::ConcernEvidenceRef
    end

    def collect_concerns(ast)
      out = []

      walk(ast) do |node|
        next unless node.is_a?(::Parser::AST::Node)

        case node.type
        when :send, :csend
          classify_send(node, out)
        when :index
          receiver = node.children[0]
          next unless receiver.is_a?(::Parser::AST::Node)
          recv_name = receiver_name(receiver)
          if %w[session cookies].include?(recv_name)
            out << make_concern('state', node.loc.line, "#{recv_name}[]")
          elsif recv_name == 'ENV'
            out << make_concern('config', node.loc.line, 'ENV[]')
          end
        when :gvar
          name = node.children[0].to_s
          out << make_concern('state', node.loc.line, name, 'global variable')
        end
      end

      walk(ast) do |node|
        next unless node.is_a?(::Parser::AST::Node)
        next unless %i[def defs].include?(node.type)
        if cyclomatic_complexity(node) >= BUSINESS_COMPLEXITY
          name = node.type == :def ? node.children[0].to_s : node.children[1].to_s
          out << make_concern('business', node.loc.line, name, 'complex method')
        end
      end

      out
    end

    def classify_send(node, out)
      receiver, method = node.children[0], node.children[1]
      line = node.loc.line

      recv_name = receiver_name(receiver)
      method_s = method.to_s

      # Rails.cache, Rails.application.config — state / config.
      if recv_name == 'Rails' && method_s == 'cache'
        out << make_concern('state', line, 'Rails.cache')
        return
      end

      # Network: Net::HTTP, Faraday, HTTParty, RestClient.
      if %w[Net::HTTP Faraday HTTParty RestClient].include?(recv_name)
        if %w[get post put delete patch head options new start request].include?(method_s)
          out << make_concern('network', line, "#{recv_name}.#{method_s}")
          return
        end
      end

      # ActiveRecord query methods on Model receivers (capitalized
      # const).
      if receiver.is_a?(::Parser::AST::Node) && receiver.type == :const
        query_methods = %w[where find find_by first last all pluck order limit
                           create update destroy save count exists?]
        if query_methods.include?(method_s)
          out << make_concern('dataaccess', line, "#{recv_name}.#{method_s}")
          return
        end
      end

      # IO: File / IO / Dir.
      if %w[File IO Dir].include?(recv_name)
        out << make_concern('io', line, "#{recv_name}.#{method_s}")
        return
      end

      # Config: ENV.fetch, ENV.foo etc.
      if recv_name == 'ENV'
        out << make_concern('config', line, "ENV.#{method_s}")
        return
      end
    end

    # Returns a human-readable name for a receiver node, or "".
    def receiver_name(node)
      return '' if node.nil?
      return '' unless node.is_a?(::Parser::AST::Node)

      case node.type
      when :const
        parent = node.children[0]
        name = node.children[1].to_s
        if parent && parent.is_a?(::Parser::AST::Node) && parent.type == :const
          "#{receiver_name(parent)}::#{name}"
        else
          name
        end
      when :send
        node.children[1].to_s
      else
        ''
      end
    end

    def make_concern(category, line, symbol, note = '')
      concern_ref_class.new(
        category: category,
        line: line,
        symbol: symbol,
        note: note,
      )
    end

    # ────────────────────────────────────────────────
    # Generic tree walker
    # ────────────────────────────────────────────────

    # Iterative pre-order traversal. Yields every
    # Parser::AST::Node descendant (including the root).
    def walk(root)
      stack = [root]
      until stack.empty?
        node = stack.pop
        next if node.nil?
        next unless node.is_a?(::Parser::AST::Node)
        yield node
        # Push children in reverse so they pop in document
        # order.
        node.children.reverse_each do |child|
          stack.push(child)
        end
      end
    end
  end
end
