#include "ledger.h"

#include <cstring>
#include <ctime>
#include <cctype>

namespace ledger {

static char * next_element(char * buf, bool variable = false)
{
  char * p;

  // Convert any tabs to spaces, for simplicity's sake
  for (p = buf; *p; p++)
    if (*p == '\t')
      *p = ' ';

  if (variable)
    p = std::strstr(buf, "  ");
  else
    p = std::strchr(buf, ' ');

  if (! p)
    return NULL;

  *p++ = '\0';
  while (std::isspace(*p))
    p++;

  return p;
}

static int linenum = 0;

static inline void finalize_entry(entry * curr)
{
  if (curr) {
    if (! curr->validate()) {
      std::cerr << "Failed to balance the following transaction, "
		<< "ending on line " << (linenum - 1) << std::endl;
      curr->print(std::cerr);
    } else {
      main_ledger.entries.push_back(curr);
    }
  }
}

//////////////////////////////////////////////////////////////////////
//
// Ledger parser
//

bool parse_ledger(std::istream& in, bool compute_balances)
{
  std::time_t      now          = std::time(NULL);
  struct std::tm * now_tm       = std::localtime(&now);
  int              current_year = now_tm->tm_year + 1900;

  char line[1024];

  struct std::tm moment;
  memset(&moment, 0, sizeof(struct std::tm));

  entry * curr = NULL;

  // Compile the regular expression used for parsing amounts
  const char *error;
  int erroffset;
  static const std::string regexp =
    "^(([0-9]{4})[./])?([0-9]+)[./]([0-9]+)\\s+(\\*\\s+)?"
    "(\\(([^)]+)\\)\\s+)?(.+)";
  pcre * entry_re = pcre_compile(regexp.c_str(), 0,
				 &error, &erroffset, NULL);

  while (! in.eof()) {
    in.getline(line, 1023);
    linenum++;

    if (line[0] == '\n') {
      continue;
    }
    else if (std::isdigit(line[0])) {
      static char buf[256];
      int ovector[60];

      int matched = pcre_exec(entry_re, NULL, line, std::strlen(line),
			      0, 0, ovector, 60);
      if (! matched) {
	std::cerr << "Failed to parse, line " << linenum << ": "
		  << line << std::endl;
	continue;
      }

      // If we haven't finished with the last entry yet, do so now

      if (curr)
	finalize_entry(curr);

      curr = new entry;

      // Parse the date

      int year = current_year;
      if (ovector[1 * 2] >= 0) {
	pcre_copy_substring(line, ovector, matched, 2, buf, 255);
	year = std::atoi(buf);
      }

      assert(ovector[3 * 2] >= 0);
      pcre_copy_substring(line, ovector, matched, 3, buf, 255);
      int mon = std::atoi(buf);

      assert(ovector[4 * 2] >= 0);
      pcre_copy_substring(line, ovector, matched, 4, buf, 255);
      int mday = std::atoi(buf);

      moment.tm_mday = mday;
      moment.tm_mon  = mon - 1;
      moment.tm_year = year - 1900;

      curr->date = std::mktime(&moment);

      // Parse the remaining entry details

      if (ovector[5 * 2] >= 0)
	curr->cleared = true;

      if (ovector[6 * 2] >= 0) {
	pcre_copy_substring(line, ovector, matched, 7, buf, 255);
	curr->code = buf;
      }

      if (ovector[8 * 2] >= 0) {
	int result = pcre_copy_substring(line, ovector, matched, 8, buf, 255);
	assert(result >= 0);
	curr->desc = buf;
      }
    }
    else if (std::isspace(line[0])) {
      transaction * xact = new transaction();

      char * p = line;
      while (std::isspace(*p))
	p++;

      // The call to `next_element' will skip past the account name,
      // and return a pointer to the beginning of the amount.  Once
      // we know where the amount is, we can strip off any
      // transaction note, and parse it.

      char * cost_str = next_element(p, true);
      char * note_str;

      // If there is no amount given, it is intended as an implicit
      // amount; we must use the opposite of the value of the
      // preceding transaction.

      if (! cost_str || ! *cost_str || *cost_str == ';') {
	if (cost_str && *cost_str) {
	  while (*cost_str == ';' || std::isspace(*cost_str))
	    cost_str++;
	  xact->note = cost_str;
	}

	xact->cost = curr->xacts.front()->cost->copy();
	xact->cost->negate();
      }
      else {
	note_str = std::strchr(cost_str, ';');
	if (note_str) {
	  *note_str++ = '\0';
	  while (std::isspace(*note_str))
	    note_str++;
	  xact->note = note_str;
	}

	for (char * t = cost_str + (std::strlen(cost_str) - 1);
	     std::isspace(*t);
	     t--)
	  *t = '\0';

	xact->cost = create_amount(cost_str);
      }

#ifdef HUQUQULLAH
      bool exempt_or_necessary = false;
      if (compute_huquq) {
	if (*p == '!') {
	  exempt_or_necessary = true;
	  p++;
	}
	else if (matches(huquq_categories, p)) {
	  exempt_or_necessary = true;
	}
      }
#endif

      xact->acct = main_ledger.find_account(p);
      if (compute_balances)
	xact->acct->balance.credit(xact->cost);

      curr->xacts.push_back(xact);

#ifdef HUQUQULLAH
      if (exempt_or_necessary) {
	static amount * huquq = create_amount("H 1.00");
	amount * temp;

	// Reflect the exempt or necessary transaction in the
	// Huququ'llah account, using the H commodity, which is 19%
	// of whichever DEFAULT_COMMODITY ledger was compiled with.
	transaction * t = new transaction();
	t->acct = main_ledger.find_account("Huququ'llah");
	temp = xact->cost->value();
	t->cost = temp->value(huquq);
	delete temp;
	curr->xacts.push_back(t);

	if (compute_balances)
	  t->acct->balance.credit(t->cost);

	// Balance the above transaction by recording the inverse in
	// Expenses:Huququ'llah.
	t = new transaction();
	t->acct = main_ledger.find_account("Expenses:Huququ'llah");
	temp = xact->cost->value();
	t->cost = temp->value(huquq);
	delete temp;
	t->cost->negate();
	curr->xacts.push_back(t);

	if (compute_balances)
	  t->acct->balance.credit(t->cost);
      }
#endif
    }
    else if (line[0] == 'Y') {
      current_year = std::atoi(line + 2);
    }
  }

  if (curr)
    finalize_entry(curr);

  return true;
}

} // namespace ledger
