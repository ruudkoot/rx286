/* ============================================================================
 * rx286 - src/bin/sh/sh.c
 * The shell (roadmap os-server.md P9, D14): POSIX-like, in C, a process
 * that init starts from /z and starts again when it ends.
 *
 * It reads a line from the terminal, raw: it echoes what is typed, takes
 * Backspace, recalls its last lines on the arrows Up and Down, and drops
 * the line at ^C. A line is a list of pipelines joined by ;, &&, || and &
 * (in the background); a pipeline commands joined by |; a command words,
 * with <, >, >> and 2> redirections. Words are split at blanks; '...' quotes all, "..."
 * all but $, and \ the next character; $NAME, ${NAME} and $? are
 * replaced. The first word of a command may be an alias. The built-ins are
 * cd, pwd, exit, export, unset, set, alias, unalias, true, false, jobs, fg,
 * bg and help (P12); any other command is a program, found along PATH
 * (execvp), run in a child. Paths may name a drive DOS's way: "c:/docs" is
 * "/c/docs".
 *
 * Job control (P11, XCU 2.11): at its start on a terminal the shell leads a
 * session whose terminal it is. Each pipeline is a job, a process group of
 * its own, which it makes the terminal's foreground while it waits for it.
 * ^Z stops the job, which jobs lists, fg brings back and bg continues in the
 * background; a job's stop or end in the background is said before the
 * next prompt.
 * ============================================================================ */

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "errno.h"
#include "fcntl.h"
#include "signal.h"
#include "termios.h"
#include "unistd.h"
#include "sys/wait.h"

#define LINE_MAX 128                    /* a line's characters */
#define WORDS 32                        /* a line's words and operators */
#define POOL 512                        /* their text, expanded */
#define PIPELINE 6                      /* a pipeline's commands */
#define VARS 24
#define ALIASES 12
#define HISTORY 8
#define JOBS 8

enum { T_WORD, T_PIPE, T_SEMI, T_AND, T_OR, T_BG, T_IN, T_OUT, T_APPEND, T_ERR, T_END };
enum { J_FREE, J_RUNNING, J_STOPPED, J_DONE };

/* A token: its kind, its text (a word's, expanded), whether it was quoted */
struct token {
    int kind;
    char *text;
    int quoted;
};

/* A command: its words and its redirections */
struct command {
    char *argv[WORDS + 1];
    int argc;
    char *in, *out, *err;
    int append;
};

static char *vars[VARS];                /* "NAME=value" */
static unsigned char exported[VARS];
static char *aliases[ALIASES];          /* "name=value" */
static char history[HISTORY][LINE_MAX];
static int history_count, status;
static struct token tokens[WORDS + 1];
static char pool[POOL];
static unsigned pool_used;
static struct command cmds[PIPELINE];

/* A job: a pipeline's processes, in a group of their own; whether its
 * state has been said; its last command's status; its text */
struct job {
    int state, said;
    pid_t pgid, pids[PIPELINE];
    int n, left, code;
    char text[40];
};

static struct job jobs[JOBS + 1];       /* (the last: a foreground job without room) */
static struct job *last_job;            /* fg's and bg's when none is named */
static pid_t shell_pgid;
static int job_control;                 /* the terminal's ours: jobs are groups */

/* say - a text on descriptor 2 */
static void say(const char *s)
{
    write(2, s, strlen(s));
}

/* complain - "sh: what: why" */
static void complain(const char *what, int e)
{
    say("sh: ");
    say(what);
    say(": ");
    say(strerror(e));
    say("\n");
}

/* var_find - a variable's place, or -1 */
static int var_find(const char *name, size_t n)
{
    int k;

    for (k = 0; k < VARS; k++)
        if (vars[k] && strncmp(vars[k], name, n) == 0 && vars[k][n] == '=')
            return k;
    return -1;
}

/* var_get - a variable's value, or NULL */
static char *var_get(const char *name, size_t n)
{
    int k = var_find(name, n);

    return k < 0 ? 0 : vars[k] + n + 1;
}

/* var_set - "NAME=value" set, exported if asked (or exported before) */
static void var_set(const char *text, int export)
{
    size_t n = strchr(text, '=') - text;
    int k = var_find(text, n);
    char *copy = malloc(strlen(text) + 1);

    if (!copy)
        return;
    strcpy(copy, text);
    if (k < 0)
        for (k = 0; k < VARS && vars[k]; k++)
            ;
    if (k == VARS) {
        free(copy);
        say("sh: too many variables\n");
        return;
    }
    if (vars[k])
        free(vars[k]);
    else
        exported[k] = 0;
    vars[k] = copy;
    exported[k] |= (unsigned char)export;
}

/* environment - the exported variables, as a child's environ */
static char **environment(void)
{
    static char *list[VARS + 1];
    int k, n = 0;

    for (k = 0; k < VARS; k++)
        if (vars[k] && exported[k])
            list[n++] = vars[k];
    list[n] = 0;
    return list;
}

/* keep - a character into the pool */
static int keep(char c)
{
    if (pool_used >= POOL)
        return -1;
    pool[pool_used++] = c;
    return 0;
}

/* name_end - where a variable's name ends */
static const char *name_end(const char *s)
{
    while ((*s >= 'A' && *s <= 'Z') || (*s >= 'a' && *s <= 'z') || (*s >= '0' && *s <= '9')
           || *s == '_')
        s++;
    return s;
}

/* expand - $NAME, ${NAME} or $? at s (s at the $): the pool given its
 * value; past it */
static const char *expand(const char *s)
{
    const char *start, *end, *value;
    char number[8];

    s++;
    if (*s == '?') {
        snprintf(number, sizeof number, "%d", status);
        for (value = number; *value; value++)
            keep(*value);
        return s + 1;
    }
    start = *s == '{' ? s + 1 : s;
    end = name_end(start);
    if (end == start) {
        keep('$');
        return s;
    }
    value = var_get(start, (size_t)(end - start));
    while (value && *value)
        keep(*value++);
    return *s == '{' && *end == '}' ? end + 1 : end;
}

/* lex - a line as tokens, its words expanded into the pool: their count,
 * or -1 for a fault said */
static int lex(const char *s, int first)
{
    int n = first;
    char quote;

    for (;;) {
        while (*s == ' ' || *s == '\t')
            s++;
        if (n >= WORDS) {
            say("sh: too many words\n");
            return -1;
        }
        tokens[n].quoted = 0;
        tokens[n].text = 0;
        if (*s == 0) {
            tokens[n].kind = T_END;
            return n;
        }
        if (*s == '|' || *s == ';' || *s == '&' || *s == '<' || *s == '>'
                || (*s == '2' && s[1] == '>')) {
            if (*s == '|' && s[1] == '|') {
                tokens[n].kind = T_OR;
                s += 2;
            } else if (*s == '&' && s[1] == '&') {
                tokens[n].kind = T_AND;
                s += 2;
            } else if (*s == '>' && s[1] == '>') {
                tokens[n].kind = T_APPEND;
                s += 2;
            } else if (*s == '2') {
                tokens[n].kind = T_ERR;
                s += 2;
            } else if (*s == '&') {
                say("sh: & is for job control, which comes later\n");
                return -1;
            } else {
                tokens[n].kind = *s == '|' ? T_PIPE : *s == ';' ? T_SEMI : *s == '<' ? T_IN
                                 : T_OUT;
                s++;
            }
            n++;
            continue;
        }
        tokens[n].kind = T_WORD;
        tokens[n].text = pool + pool_used;
        while (*s && *s != ' ' && *s != '\t' && !strchr("|;&<>", *s)) {
            if (*s == '\'' || *s == '"') {
                quote = *s++;
                tokens[n].quoted = 1;
                while (*s && *s != quote) {
                    if (quote == '"' && *s == '$')
                        s = expand(s);
                    else if (quote == '"' && *s == '\\' && s[1])
                        keep(*++s), s++;
                    else
                        keep(*s++);
                }
                if (*s != quote) {
                    say("sh: a quote is not closed\n");
                    return -1;
                }
                s++;
            } else if (*s == '\\' && s[1]) {
                tokens[n].quoted = 1;
                keep(s[1]);
                s += 2;
            } else if (*s == '$') {
                s = expand(s);
            } else {
                keep(*s++);
            }
        }
        if (keep(0) < 0) {
            say("sh: the line is too long\n");
            return -1;
        }
        n++;
    }
}

/* alias_of - an alias's value, or NULL */
static char *alias_of(const char *name)
{
    size_t n = strlen(name);
    int k;

    for (k = 0; k < ALIASES; k++)
        if (aliases[k] && strncmp(aliases[k], name, n) == 0 && aliases[k][n] == '=')
            return aliases[k] + n + 1;
    return 0;
}

/* parse - a pipeline's commands, from token t on: how many, its end in
 * *next; -1 for a fault said */
static int parse(int t, int *next)
{
    struct command *c;
    int n = 0, kind;

    memset(cmds, 0, sizeof cmds);
    c = &cmds[0];
    for (;; t++) {
        kind = tokens[t].kind;
        if (kind == T_WORD) {
            if (c->argc == WORDS)
                return -1;
            c->argv[c->argc++] = tokens[t].text;
        } else if (kind == T_IN || kind == T_OUT || kind == T_APPEND || kind == T_ERR) {
            if (tokens[t + 1].kind != T_WORD) {
                say("sh: a redirection names no file\n");
                return -1;
            }
            if (kind == T_IN)
                c->in = tokens[++t].text;
            else if (kind == T_ERR)
                c->err = tokens[++t].text;
            else {
                c->out = tokens[++t].text;
                c->append = kind == T_APPEND;
            }
        } else {
            if (c->argc == 0 && (kind == T_PIPE || n > 0)) {
                say("sh: a command is missing\n");
                return -1;
            }
            if (c->argc)
                n++;
            if (kind != T_PIPE) {
                *next = t;
                return n;
            }
            if (n == PIPELINE) {
                say("sh: the pipeline is too long\n");
                return -1;
            }
            c = &cmds[n];
        }
    }
}

/* redirect - a command's redirections, onto descriptors 0, 1, 2: 0, or -1
 * with the fault said */
static int redirect(struct command *c)
{
    int fd;

    if (c->in) {
        if ((fd = open(c->in, O_RDONLY)) < 0) {
            complain(c->in, errno);
            return -1;
        }
        dup2(fd, 0);
        close(fd);
    }
    if (c->out) {
        if ((fd = open(c->out, O_WRONLY | O_CREAT | (c->append ? O_APPEND : O_TRUNC))) < 0) {
            complain(c->out, errno);
            return -1;
        }
        dup2(fd, 1);
        close(fd);
    }
    if (c->err) {
        if ((fd = open(c->err, O_WRONLY | O_CREAT | O_TRUNC)) < 0) {
            complain(c->err, errno);
            return -1;
        }
        dup2(fd, 2);
        close(fd);
    }
    return 0;
}

/* job_new - a job of a pipeline's processes: a free one of the table, or
 * the spare for a foreground job without room */
static struct job *job_new(pid_t pgid, const pid_t *pids, int n, const char *text)
{
    struct job *j = &jobs[JOBS];
    int k;

    for (k = 0; k < JOBS; k++)
        if (jobs[k].state == J_FREE) {
            j = &jobs[k];
            break;
        }
    memset(j, 0, sizeof *j);
    j->state = J_RUNNING;
    j->pgid = pgid;
    j->n = n;
    for (k = 0; k < n; k++)
        if ((j->pids[k] = pids[k] > 0 ? pids[k] : 0) != 0)
            j->left++;
    while (*text == ' ' || *text == '\t')
        text++;
    strncpy(j->text, text, sizeof j->text - 1);
    for (k = (int)strlen(j->text); k > 0 && j->text[k - 1] == ' '; k--)
        j->text[k - 1] = 0;
    return j;
}

/* job_update - a child's news, waitpid's status, for its job */
static void job_update(pid_t pid, int st)
{
    struct job *j;
    int k;

    for (j = jobs; j <= &jobs[JOBS]; j++) {
        if (j->state == J_FREE || j->state == J_DONE)
            continue;
        for (k = 0; k < j->n && j->pids[k] != pid; k++)
            ;
        if (k == j->n)
            continue;
        if (WIFSTOPPED(st)) {
            j->state = J_STOPPED;
            j->code = 128 + WSTOPSIG(st);
            j->said = 0;
            if (j != &jobs[JOBS])
                last_job = j;
        } else if (WIFCONTINUED(st)) {
            j->state = J_RUNNING;
        } else {
            if (k == j->n - 1)
                j->code = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
            j->pids[k] = 0;
            if (--j->left == 0) {
                j->state = J_DONE;
                j->said = 0;
            }
        }
        return;
    }
}

/* job_say - a job, as jobs says it */
static void job_say(struct job *j)
{
    static const char *const words[] = { "", "Running", "Stopped", "Done" };

    printf("[%d] %s  %s\n", (int)(j - jobs) + 1, words[j->state], j->text);
    j->said = 1;
}

/* job_reap - the children's news, without waiting; a job stopped or done
 * since it was said, said if asked; the done ones said, forgotten */
static void job_reap(int say)
{
    pid_t pid;
    int st, k;

    while ((pid = waitpid(-1, &st, WNOHANG | WUNTRACED)) > 0)
        job_update(pid, st);
    for (k = 0; k < JOBS; k++) {
        if (jobs[k].state == J_FREE)
            continue;
        if (say && !jobs[k].said && jobs[k].state != J_RUNNING)
            job_say(&jobs[k]);
        if (jobs[k].state == J_DONE && jobs[k].said) {
            jobs[k].state = J_FREE;
            if (last_job == &jobs[k])
                last_job = 0;
        }
    }
}

/* job_wait - a job in the terminal's foreground until it ends or stops:
 * its status (128 and the signal for a stop) */
static int job_wait(struct job *j)
{
    pid_t pid;
    int st, code;

    if (job_control)
        tcsetpgrp(0, j->pgid);
    while (j->state == J_RUNNING) {
        pid = waitpid(-1, &st, WUNTRACED);
        if (pid < 0) {
            if (errno == EINTR)
                continue;
            j->state = J_DONE;          /* (its processes gone) */
            break;
        }
        job_update(pid, st);
    }
    if (job_control)
        tcsetpgrp(0, shell_pgid);
    code = j->code;
    if (j->state == J_STOPPED) {
        job_say(j);
    } else {
        j->state = J_FREE;
        if (last_job == j)
            last_job = 0;
    }
    return code;
}

/* job_pick - the job "%n" names, or the last one */
static struct job *job_pick(const char *name)
{
    int n;

    if (!name)
        return last_job;
    n = atoi(name[0] == '%' ? name + 1 : name);
    if (n < 1 || n > JOBS || jobs[n - 1].state == J_FREE || jobs[n - 1].state == J_DONE)
        return 0;
    return &jobs[n - 1];
}

/* help's: the built-ins, the programs (in /z and /c/bin), the keys */
static const char help_text[] =
    "Built in:  cd [DIR], pwd, exit [STATUS], export NAME=VALUE, unset NAME, set,\n"
    "           alias NAME=VALUE, unalias NAME, jobs, fg [%N], bg [%N], true,\n"
    "           false, help\n"
    "Files:     ls [-l], cat, head [-n N], wc, cp, mv, rm, mkdir, rmdir, more,\n"
    "           lp (to the printer), echo\n"
    "Processes: ps [-e], kill [-SIGNAL] PID, sleep SECONDS, env [NAME=VALUE] [CMD]\n"
    "Machine:   date [+FORMAT], uptime, clear, keys, mem, fpu, crash KIND, spin\n"
    "Devices:   beep, play, joy, mouse, term (COM2)\n"
    "Lines:     CMD | CMD, CMD; CMD, && ||, & (in the background), < > >> 2>\n"
    "Keys:      Backspace, Up and Down (the last lines), ^C (stop), ^Z (stop a\n"
    "           job), ^D (the end), Alt+F1 to F8 (the terminals)\n";

/* builtin - a built-in command, run: its status; -1 if it is none */
static int builtin(struct command *c)
{
    static char cwd[PATH_MAX];
    char line[96];
    const char *name = c->argv[0], *path;
    int k;

    if (strcmp(name, "cd") == 0) {
        path = c->argc > 1 ? c->argv[1] : var_get("HOME", 4);
        if (!path)
            path = "/";
        if (chdir(path) < 0) {
            complain(path, errno);
            return 1;
        }
        return 0;
    }
    if (strcmp(name, "jobs") == 0) {
        job_reap(0);
        for (k = 0; k < JOBS; k++)
            if (jobs[k].state != J_FREE)
                job_say(&jobs[k]);
        job_reap(0);                    /* (the done ones, said: forgotten) */
        return 0;
    }
    if (strcmp(name, "fg") == 0 || strcmp(name, "bg") == 0) {
        struct job *j;

        job_reap(0);
        if (!(j = job_pick(c->argc > 1 ? c->argv[1] : 0))) {
            say("sh: no such job\n");
            return 1;
        }
        if (name[0] == 'f')
            printf("%s\n", j->text);
        else
            printf("[%d] %s &\n", (int)(j - jobs) + 1, j->text);
        j->state = J_RUNNING;
        if (name[0] == 'f' && job_control)
            tcsetpgrp(0, j->pgid);      /* the terminal first, then SIGCONT */
        kill(-j->pgid, SIGCONT);
        return name[0] == 'f' ? job_wait(j) : 0;
    }
    if (strcmp(name, "pwd") == 0) {
        if (getcwd(cwd, sizeof cwd))
            printf("%s\n", cwd);
        return 0;
    }
    if (strcmp(name, "exit") == 0)
        exit(c->argc > 1 ? atoi(c->argv[1]) : status);
    if (strcmp(name, "export") == 0 || strcmp(name, "unset") == 0) {
        for (k = 1; k < c->argc; k++) {
            if (name[0] == 'u') {
                int v = var_find(c->argv[k], strlen(c->argv[k]));

                if (v >= 0) {
                    free(vars[v]);
                    vars[v] = 0;
                }
            } else if (strchr(c->argv[k], '=')) {
                var_set(c->argv[k], 1);
            } else {
                int v = var_find(c->argv[k], strlen(c->argv[k]));

                if (v >= 0)
                    exported[v] = 1;
            }
        }
        return 0;
    }
    if (strcmp(name, "set") == 0) {
        for (k = 0; k < VARS; k++)
            if (vars[k])
                printf("%s\n", vars[k]);
        return 0;
    }
    if (strcmp(name, "alias") == 0) {
        if (c->argc == 1)
            for (k = 0; k < ALIASES; k++)
                if (aliases[k])
                    printf("alias %s\n", aliases[k]);
        for (k = 1; k < c->argc; k++) {
            int a;
            size_t n = strchr(c->argv[k], '=') ? (size_t)(strchr(c->argv[k], '=') - c->argv[k])
                                              : 0;

            if (!n) {
                snprintf(line, sizeof line, "sh: alias: %s: give name=value\n", c->argv[k]);
                say(line);
                continue;
            }
            for (a = 0; a < ALIASES; a++)
                if (aliases[a] && strncmp(aliases[a], c->argv[k], n + 1) == 0)
                    break;
            if (a == ALIASES)
                for (a = 0; a < ALIASES && aliases[a]; a++)
                    ;
            if (a == ALIASES) {
                say("sh: too many aliases\n");
                continue;
            }
            free(aliases[a]);
            aliases[a] = malloc(strlen(c->argv[k]) + 1);
            if (aliases[a])
                strcpy(aliases[a], c->argv[k]);
        }
        return 0;
    }
    if (strcmp(name, "unalias") == 0) {
        for (k = 1; k < c->argc; k++) {
            int a;
            size_t n = strlen(c->argv[k]);

            for (a = 0; a < ALIASES; a++)
                if (aliases[a] && strncmp(aliases[a], c->argv[k], n) == 0
                        && aliases[a][n] == '=') {
                    free(aliases[a]);
                    aliases[a] = 0;
                }
        }
        return 0;
    }
    if (strcmp(name, "true") == 0)
        return 0;
    if (strcmp(name, "false") == 0)
        return 1;
    if (strcmp(name, "help") == 0)
        return write(1, help_text, sizeof help_text - 1) < 0;
    return -1;
}

/* aliased - a line with the aliases of its commands' first words put in
 * (once each, not again in what they put): into out */
static void aliased(const char *s, char *out)
{
    char word[LINE_MAX];
    const char *value;
    int start = 1;
    unsigned n = 0, k;

    while (*s && n < LINE_MAX - 1) {
        if (start) {
            while ((*s == ' ' || *s == '\t') && n < LINE_MAX - 1)
                out[n++] = *s++;
            for (k = 0; s[k] && !strchr(" \t|;&<>'\"\\$", s[k]) && k < LINE_MAX - 1; k++)
                word[k] = s[k];
            word[k] = 0;
            start = 0;
            if (k && (value = alias_of(word)) != 0) {
                while (*value && n < LINE_MAX - 1)
                    out[n++] = *value++;
                s += k;
                continue;
            }
        }
        if (*s == '|' || *s == ';' || *s == '&')
            start = 1;
        if (*s == '\'' || *s == '"') {          /* a quote, whole */
            char q = *s;

            out[n++] = *s++;
            while (*s && *s != q && n < LINE_MAX - 1)
                out[n++] = *s++;
            if (*s && n < LINE_MAX - 1)
                out[n++] = *s++;
            continue;
        }
        out[n++] = *s++;
    }
    out[n] = 0;
}

/* run - a command in a child: its program along PATH (or a built-in) */
static void run(struct command *c)
{
    int code;

    if (redirect(c) < 0)
        _exit(1);
    if ((code = builtin(c)) >= 0)
        _exit(code);
    environ = environment();
    execvp(c->argv[0], c->argv);
    complain(c->argv[0], errno == ENOENT ? ENOENT : errno);
    _exit(errno == ENOENT ? 127 : 126);
}

/* defaults - the signals the shell ignores or catches, back to their
 * defaults, in a child */
static void defaults(void)
{
    signal(SIGINT, SIG_DFL);
    signal(SIGQUIT, SIG_DFL);
    signal(SIGTSTP, SIG_DFL);
    signal(SIGTTIN, SIG_DFL);
    signal(SIGTTOU, SIG_DFL);
}

/* pipeline - n commands, each in a child, joined by pipes, a job: in the
 * foreground, the last one's status; in the background, 0. A lone built-in
 * in the foreground runs in the shell itself, its descriptors as they were
 * after */
static int pipeline(int n, int background, const char *text)
{
    pid_t pids[PIPELINE], pgid = 0;
    struct job *j;
    int fds[2], in = -1, k, code = 0, saved[3];

    if (n == 1 && cmds[0].argc && !background) {
        for (k = 0; k < 3; k++)
            saved[k] = dup(k);
        code = redirect(&cmds[0]) < 0 ? 1 : builtin(&cmds[0]);
        for (k = 0; k < 3; k++) {
            dup2(saved[k], k);
            close(saved[k]);
        }
        if (code >= 0)
            return code;
    }
    for (k = 0; k < n; k++) {
        fds[0] = fds[1] = -1;
        if (k < n - 1 && pipe(fds) < 0) {
            complain("pipe", errno);
            break;
        }
        pids[k] = fork();
        if (pids[k] == 0) {
            if (job_control) {          /* the job's group; the foreground's, unless & */
                setpgid(0, pgid);
                if (!background)
                    tcsetpgrp(0, pgid ? pgid : getpid());
            }
            defaults();
            if (in >= 0) {
                dup2(in, 0);
                close(in);
            }
            if (fds[1] >= 0) {
                dup2(fds[1], 1);
                close(fds[1]);
                close(fds[0]);
            }
            run(&cmds[k]);
        }
        if (pids[k] < 0)
            complain(cmds[k].argv[0], errno);
        if (pids[k] > 0) {
            if (!pgid)
                pgid = pids[k];
            if (job_control)
                setpgid(pids[k], pgid);
        }
        if (in >= 0)
            close(in);
        if (fds[1] >= 0)
            close(fds[1]);
        in = fds[0];
    }
    if (in >= 0)
        close(in);
    if (!pgid)
        return status;                  /* none started */
    j = job_new(pgid, pids, k, text);
    if (background) {
        if (j != &jobs[JOBS])
            last_job = j;               /* the current job, as one stopped is */
        printf("[%d] %d\n", (int)(j - jobs) + 1, (int)pgid);
        return 0;
    }
    return job_wait(j);
}

/* next_part - a list's next pipeline, up to a ;, &&, || or & outside
 * quotes, into part: past it, its operator in *op (T_END at the line's end) */
static const char *next_part(const char *s, char *part, int *op)
{
    unsigned n = 0;
    char quote = 0;

    *op = T_END;
    for (; *s; s++) {
        if (quote) {
            if (*s == quote)
                quote = 0;
        } else if (*s == '\'' || *s == '"') {
            quote = *s;
        } else if (*s == '\\' && s[1]) {
            part[n++] = *s++;
        } else if (*s == ';' || *s == '&' || (*s == '|' && s[1] == '|')) {
            *op = *s == ';' ? T_SEMI : *s == '|' ? T_OR : s[1] == '&' ? T_AND : T_BG;
            s += *op == T_AND || *op == T_OR ? 2 : 1;
            break;
        }
        part[n++] = *s;
    }
    part[n] = 0;
    return s;
}

/* assignments - a command of NAME=value words alone: each variable set,
 * not exported; 0 if the command is no such */
static int assignments(struct command *c)
{
    const char *e;
    int k;

    for (k = 0; k < c->argc; k++) {
        e = name_end(c->argv[k]);
        if (e == c->argv[k] || *e != '=' || (*c->argv[k] >= '0' && *c->argv[k] <= '9'))
            return 0;
    }
    for (k = 0; k < c->argc; k++)
        var_set(c->argv[k], 0);
    return 1;
}

/* run_line - a line's list: its aliases put in when it is read, each
 * pipeline then expanded as it comes, run as ;, && and || say */
static void run_line(const char *line)
{
    char text[LINE_MAX], part[LINE_MAX];
    const char *s = text;
    int kind = T_SEMI, op, n, next;

    aliased(line, text);
    while (*s || kind != T_END) {
        s = next_part(s, part, &op);
        if (kind == T_SEMI || (kind == T_AND && status == 0) || (kind == T_OR && status != 0)) {
            pool_used = 0;
            if (lex(part, 0) < 0 || (n = parse(0, &next)) < 0) {
                status = 2;
                return;
            }
            if (n == 1 && cmds[0].argc && !cmds[0].in && !cmds[0].out && !cmds[0].err
                    && assignments(&cmds[0]))
                status = 0;
            else if (n)
                status = pipeline(n, op == T_BG, part);
        }
        kind = op == T_BG ? T_SEMI : op;
        if (op == T_END)
            break;
    }
}

/* erase - the line on the screen rubbed out */
static void erase(unsigned n)
{
    while (n--)
        write(1, "\b \b", 3);
}

/* line_read - a line from the terminal, edited: its length, or -1 at its
 * end */
static int line_read(char *line)
{
    char in[8], cwd[PATH_MAX];
    unsigned n = 0, at = (unsigned)history_count;
    int got, k;

    if (!getcwd(cwd, sizeof cwd))
        strcpy(cwd, "?");
    printf("%s$ ", cwd);
    for (;;) {
        got = read(0, in, sizeof in);
        if (got < 0 && errno == EINTR) {
            write(1, "^C\n", 3);        /* ^C: the line dropped */
            line[0] = 0;
            return 0;
        }
        if (got <= 0)
            return -1;
        if (got == 3 && in[0] == 0x1B && in[1] == '[' && (in[2] == 'A' || in[2] == 'B')) {
            if (in[2] == 'A' && at > 0 && history_count - at < HISTORY)
                at--;
            else if (in[2] == 'B' && at < (unsigned)history_count)
                at++;
            else
                continue;
            erase(n);
            if (at < (unsigned)history_count)
                strcpy(line, history[at % HISTORY]);
            else
                line[0] = 0;
            n = strlen(line);
            write(1, line, n);
            continue;
        }
        for (k = 0; k < got; k++) {
            if (in[k] == '\r' || in[k] == '\n') {
                write(1, "\n", 1);
                line[n] = 0;
                return (int)n;
            }
            if (in[k] == '\b' || in[k] == 0x7F) {
                if (n) {
                    n--;
                    erase(1);
                }
            } else if (in[k] >= ' ' && in[k] < 0x7F && n < LINE_MAX - 1) {
                line[n++] = in[k];
                write(1, &in[k], 1);
            }
        }
    }
}

static struct termios cooked, raw;     /* the terminal's, and the editor's */
static int terminal;                    /* descriptor 0 is one */

/* editing - the terminal raw while a line is edited (1), as it was while
 * a command runs (0) */
static void editing(int on)
{
    if (terminal)
        tcsetattr(0, TCSANOW, on ? &raw : &cooked);
}

/* on_interrupt - SIGINT's handler: the read it breaks off ends the line */
static void on_interrupt(int sig)
{
    (void)sig;
}

/* take_terminal - at the start on a terminal: a session of the shell's
 * whose terminal it is, and the job control signals ignored */
static void take_terminal(void)
{
    struct sigaction act;
    int fd;

    signal(SIGQUIT, SIG_IGN);
    signal(SIGTSTP, SIG_IGN);
    signal(SIGTTIN, SIG_IGN);
    signal(SIGTTOU, SIG_IGN);
    act.sa_handler = on_interrupt;      /* (no SA_RESTART: the read ends) */
    act.sa_mask = 0;
    act.sa_flags = 0;
    sigaction(SIGINT, &act, 0);
    setsid();                           /* (a group's leader already: it stays) */
    if ((fd = open("/dev/tty", O_RDWR)) >= 0)
        close(fd);                      /* a session's leader's: its terminal */
    shell_pgid = getpgrp();
    job_control = tcgetpgrp(0) == shell_pgid;
}

/* main - the environment taken in, then line after line */
int main(int argc, char **argv, char **envp)
{
    char line[LINE_MAX];
    int n;

    (void)argc;
    (void)argv;
    for (; envp && *envp; envp++)
        if (strchr(*envp, '='))
            var_set(*envp, 1);
    if (var_get("HOME", 4))
        chdir(var_get("HOME", 4));      /* (init's: /a, the boot drive) */
    if (tcgetattr(0, &cooked) == 0) {   /* the editor's: key by key, its own echo */
        terminal = 1;
        take_terminal();
        raw = cooked;
        raw.c_lflag &= (tcflag_t)~(ICANON | ECHO);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;
    }
    for (;;) {
        job_reap(1);                    /* the jobs' news, before the prompt */
        editing(1);
        n = line_read(line);
        editing(0);
        if (n < 0)
            return status;
        if (n == 0)
            continue;
        strcpy(history[history_count++ % HISTORY], line);
        run_line(line);
    }
}
