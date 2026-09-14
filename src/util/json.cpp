#include "util/json.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace va {

const Json& Json::none() {
    static const Json empty;
    return empty;
}

const Json& Json::operator[](const std::string& key) const {
    if (type_ != Type::Object) return none();
    auto it = object_.find(key);
    return it == object_.end() ? none() : it->second;
}

const Json& Json::operator[](std::size_t index) const {
    if (type_ != Type::Array || index >= array_.size()) return none();
    return array_[index];
}

std::size_t Json::size() const {
    if (type_ == Type::Array) return array_.size();
    if (type_ == Type::Object) return object_.size();
    return 0;
}

bool Json::has(const std::string& key) const {
    return type_ == Type::Object && object_.find(key) != object_.end();
}

double Json::asDouble(double fallback) const {
    if (type_ == Type::Number) return number_;
    if (type_ == Type::Bool) return bool_ ? 1.0 : 0.0;
    return fallback;
}

int Json::asInt(int fallback) const {
    if (type_ == Type::Number) return static_cast<int>(number_);
    if (type_ == Type::Bool) return bool_ ? 1 : 0;
    return fallback;
}

bool Json::asBool(bool fallback) const {
    if (type_ == Type::Bool) return bool_;
    if (type_ == Type::Number) return number_ != 0.0;
    return fallback;
}

std::string Json::asString(const std::string& fallback) const {
    if (type_ == Type::String) return string_;
    return fallback;
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

class JsonParser {
public:
    explicit JsonParser(const std::string& text) : s_(text) {}

    bool parse(Json* out) {
        skipSpace();
        if (!parseValue(out)) return false;
        skipSpace();
        return true;  // trailing content is tolerated
    }

    const std::string& error() const { return error_; }

private:
    const std::string& s_;
    std::size_t p_ = 0;
    std::string error_;

    bool fail(const char* msg) {
        if (error_.empty()) {
            error_ = std::string(msg) + " at offset " + std::to_string(p_);
        }
        return false;
    }

    void skipSpace() {
        while (p_ < s_.size()) {
            char c = s_[p_];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                ++p_;
            } else {
                break;
            }
        }
    }

    bool literal(const char* word) {
        std::size_t n = std::strlen(word);
        if (s_.compare(p_, n, word) != 0) return false;
        p_ += n;
        return true;
    }

    bool parseValue(Json* out) {
        if (p_ >= s_.size()) return fail("unexpected end of input");
        switch (s_[p_]) {
            case '{': return parseObject(out);
            case '[': return parseArray(out);
            case '"':
                out->type_ = Json::Type::String;
                return parseString(&out->string_);
            case 't':
                if (!literal("true")) return fail("bad literal");
                out->type_ = Json::Type::Bool;
                out->bool_ = true;
                return true;
            case 'f':
                if (!literal("false")) return fail("bad literal");
                out->type_ = Json::Type::Bool;
                out->bool_ = false;
                return true;
            case 'n':
                if (!literal("null")) return fail("bad literal");
                out->type_ = Json::Type::Null;
                return true;
            default: return parseNumber(out);
        }
    }

    bool parseNumber(Json* out) {
        std::size_t start = p_;
        if (p_ < s_.size() && (s_[p_] == '-' || s_[p_] == '+')) ++p_;
        bool digits = false;
        while (p_ < s_.size() && s_[p_] >= '0' && s_[p_] <= '9') {
            ++p_;
            digits = true;
        }
        if (p_ < s_.size() && s_[p_] == '.') {
            ++p_;
            while (p_ < s_.size() && s_[p_] >= '0' && s_[p_] <= '9') {
                ++p_;
                digits = true;
            }
        }
        if (!digits) return fail("expected a number");
        if (p_ < s_.size() && (s_[p_] == 'e' || s_[p_] == 'E')) {
            ++p_;
            if (p_ < s_.size() && (s_[p_] == '-' || s_[p_] == '+')) ++p_;
            while (p_ < s_.size() && s_[p_] >= '0' && s_[p_] <= '9') ++p_;
        }
        // strtod honours the C locale for the decimal separator; JSON always
        // uses '.', so the mantissa is scanned by hand to stay locale neutral.
        out->type_ = Json::Type::Number;
        out->number_ = parseDecimal(s_.substr(start, p_ - start));
        return true;
    }

    static double parseDecimal(const std::string& t) {
        std::size_t i = 0;
        double sign = 1.0;
        if (i < t.size() && (t[i] == '-' || t[i] == '+')) {
            if (t[i] == '-') sign = -1.0;
            ++i;
        }
        double value = 0.0;
        while (i < t.size() && t[i] >= '0' && t[i] <= '9') {
            value = value * 10.0 + (t[i] - '0');
            ++i;
        }
        if (i < t.size() && t[i] == '.') {
            ++i;
            double scale = 0.1;
            while (i < t.size() && t[i] >= '0' && t[i] <= '9') {
                value += (t[i] - '0') * scale;
                scale *= 0.1;
                ++i;
            }
        }
        if (i < t.size() && (t[i] == 'e' || t[i] == 'E')) {
            ++i;
            int esign = 1;
            if (i < t.size() && (t[i] == '-' || t[i] == '+')) {
                if (t[i] == '-') esign = -1;
                ++i;
            }
            int exp = 0;
            while (i < t.size() && t[i] >= '0' && t[i] <= '9') {
                exp = exp * 10 + (t[i] - '0');
                ++i;
            }
            value *= std::pow(10.0, esign * exp);
        }
        return sign * value;
    }

    // Appends the UTF-8 encoding of one code point.
    static void appendUtf8(std::string* out, unsigned int cp) {
        if (cp < 0x80) {
            out->push_back(static_cast<char>(cp));
        } else if (cp < 0x800) {
            out->push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out->push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out->push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out->push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }

    bool hex4(unsigned int* out) {
        if (p_ + 4 > s_.size()) return false;
        unsigned int v = 0;
        for (int i = 0; i < 4; ++i) {
            char c = s_[p_ + i];
            v <<= 4;
            if (c >= '0' && c <= '9') {
                v |= static_cast<unsigned>(c - '0');
            } else if (c >= 'a' && c <= 'f') {
                v |= static_cast<unsigned>(c - 'a' + 10);
            } else if (c >= 'A' && c <= 'F') {
                v |= static_cast<unsigned>(c - 'A' + 10);
            } else {
                return false;
            }
        }
        p_ += 4;
        *out = v;
        return true;
    }

    bool parseString(std::string* out) {
        if (p_ >= s_.size() || s_[p_] != '"') return fail("expected a string");
        ++p_;
        out->clear();
        while (p_ < s_.size()) {
            char c = s_[p_++];
            if (c == '"') return true;
            if (c != '\\') {
                out->push_back(c);
                continue;
            }
            if (p_ >= s_.size()) return fail("truncated escape");
            char e = s_[p_++];
            switch (e) {
                case '"': out->push_back('"'); break;
                case '\\': out->push_back('\\'); break;
                case '/': out->push_back('/'); break;
                case 'b': out->push_back('\b'); break;
                case 'f': out->push_back('\f'); break;
                case 'n': out->push_back('\n'); break;
                case 'r': out->push_back('\r'); break;
                case 't': out->push_back('\t'); break;
                case 'u': {
                    unsigned int cp = 0;
                    if (!hex4(&cp)) return fail("bad \\u escape");
                    // Recombine a UTF-16 surrogate pair into one code point.
                    if (cp >= 0xD800 && cp <= 0xDBFF && p_ + 1 < s_.size() &&
                        s_[p_] == '\\' && s_[p_ + 1] == 'u') {
                        std::size_t save = p_;
                        p_ += 2;
                        unsigned int low = 0;
                        if (hex4(&low) && low >= 0xDC00 && low <= 0xDFFF) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                        } else {
                            p_ = save;
                        }
                    }
                    appendUtf8(out, cp);
                    break;
                }
                default: return fail("unknown escape");
            }
        }
        return fail("unterminated string");
    }

    bool parseArray(Json* out) {
        ++p_;  // consume '['
        out->type_ = Json::Type::Array;
        skipSpace();
        if (p_ < s_.size() && s_[p_] == ']') {
            ++p_;
            return true;
        }
        while (true) {
            Json item;
            skipSpace();
            if (!parseValue(&item)) return false;
            out->array_.push_back(std::move(item));
            skipSpace();
            if (p_ >= s_.size()) return fail("unterminated array");
            if (s_[p_] == ',') {
                ++p_;
                continue;
            }
            if (s_[p_] == ']') {
                ++p_;
                return true;
            }
            return fail("expected ',' or ']'");
        }
    }

    bool parseObject(Json* out) {
        ++p_;  // consume '{'
        out->type_ = Json::Type::Object;
        skipSpace();
        if (p_ < s_.size() && s_[p_] == '}') {
            ++p_;
            return true;
        }
        while (true) {
            skipSpace();
            std::string key;
            if (!parseString(&key)) return false;
            skipSpace();
            if (p_ >= s_.size() || s_[p_] != ':') return fail("expected ':'");
            ++p_;
            skipSpace();
            Json value;
            if (!parseValue(&value)) return false;
            out->object_[key] = std::move(value);
            skipSpace();
            if (p_ >= s_.size()) return fail("unterminated object");
            if (s_[p_] == ',') {
                ++p_;
                continue;
            }
            if (s_[p_] == '}') {
                ++p_;
                return true;
            }
            return fail("expected ',' or '}'");
        }
    }
};

Json Json::parse(const std::string& text, std::string* error) {
    Json root;
    JsonParser parser(text);
    if (!parser.parse(&root)) {
        if (error) *error = parser.error();
        return Json();
    }
    if (error) error->clear();
    return root;
}

std::string Json::escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out.push_back(static_cast<char>(c));  // UTF-8 passes through
                }
        }
    }
    return out;
}

std::string Json::number(double v, int decimals) {
    if (!std::isfinite(v)) return "0";
    if (decimals < 0) decimals = 0;
    if (decimals > 9) decimals = 9;

    bool negative = v < 0;
    if (negative) v = -v;
    long long scale = 1;
    for (int i = 0; i < decimals; ++i) scale *= 10;
    // llround keeps this independent of the C locale, unlike snprintf("%f").
    long long scaled = std::llround(v * static_cast<double>(scale));
    long long whole = scaled / scale;
    long long frac = scaled % scale;

    std::string out;
    if (negative && scaled != 0) out.push_back('-');
    out += std::to_string(whole);
    if (decimals > 0) {
        std::string f = std::to_string(frac);
        out.push_back('.');
        out.append(static_cast<std::size_t>(decimals) - f.size(), '0');
        out += f;
    }
    return out;
}

}  // namespace va
