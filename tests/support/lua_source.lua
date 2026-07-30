--[[
    tests.support.lua_source — strip comments and string literals from Lua source.

    Several tests assert that a module does not name something: that only the
    platform backend says `love`, that the registry reads no wall clock. Those
    checks are worthless if they match the word inside a comment, and worse than
    worthless -- a file whose header explains "no love here" fails its own rule,
    so the honest documentation is what breaks the build.

    That is not hypothetical. It has now happened twice: once on a panel whose
    help string contained a shell command, and once on the registry's own
    HEADLESS header. A naive two-gsub strip is not enough, hence a real scan over
    line comments, block comments with = levels, quoted strings with escapes, and
    long brackets.

    Skipped text is replaced by its own newlines, so line numbers survive and
    nothing on either side of a comment is joined into a token.
]]

local function stripNonCode(src)
    local out, i, n = {}, 1, #src

    -- Skipped text is replaced by its own newlines, so line structure survives
    -- and nothing on either side of a comment is joined into a token.
    local function skipTo(from, to)
        out[#out + 1] = src:sub(from, to - 1):gsub('[^\n]', '')
        return to
    end

    while i <= n do
        local c = src:sub(i, i)

        if c == '-' and src:sub(i + 1, i + 1) == '-' then
            local eqs = src:match('^%[(=*)%[', i + 2)
            if eqs then                              -- --[[ block comment ]]
                local close = ']' .. eqs .. ']'
                local stop = src:find(close, i + 4 + #eqs, true)
                i = skipTo(i, stop and (stop + #close) or (n + 1))
            else                                     -- -- line comment
                i = skipTo(i, src:find('\n', i, true) or (n + 1))
            end

        elseif c == '[' and src:match('^%[(=*)%[', i) then
            local eqs = src:match('^%[(=*)%[', i)    -- [[ long string ]]
            local close = ']' .. eqs .. ']'
            local stop = src:find(close, i + 2 + #eqs, true)
            i = skipTo(i, stop and (stop + #close) or (n + 1))

        elseif c == '"' or c == "'" then             -- 'quoted' or "quoted"
            local from = i
            i = i + 1
            while i <= n do
                local ch = src:sub(i, i)
                if ch == '\\' then i = i + 2
                elseif ch == c then i = i + 1; break
                elseif ch == '\n' then break
                else i = i + 1 end
            end
            i = skipTo(from, i)

        else
            out[#out + 1] = c
            i = i + 1
        end
    end

    return table.concat(out)
end

return { stripNonCode = stripNonCode }
