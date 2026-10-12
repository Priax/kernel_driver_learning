#include "linux/printk.h"
#include <linux/cdev.h> /* cdev_ */
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/uaccess.h> /* put_user */

static int hello_world_driver(void)
{
    printk("Hello World ! This is such a cool driver\n");
    return 0;
}

static void exit_the_world_driver(void)
{
    printk("Such a cool driver, but everything must end...\n");
}

module_init(hello_world_driver);
module_exit(exit_the_world_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Priax");
MODULE_DESCRIPTION("A very descriptive description");
